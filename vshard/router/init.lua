local log = require('log')
local lfiber = require('fiber')

local MODULE_INTERNALS = '__module_vshard_router'
-- Reload requirements, in case this module is reloaded manually.
if rawget(_G, MODULE_INTERNALS) then
    local vshard_modules = {
        'vshard.consts', 'vshard.error', 'vshard.cfg',
        'vshard.hash', 'vshard.replicaset', 'vshard.util',
        'vshard.lua_gc',
    }
    for _, module in pairs(vshard_modules) do
        package.loaded[module] = nil
    end
end
local consts = require('vshard.consts')
local lerror = require('vshard.error')
local lcfg = require('vshard.cfg')
local lhash = require('vshard.hash')
local lreplicaset = require('vshard.replicaset')
local util = require('vshard.util')
local lua_gc = require('vshard.lua_gc')

local M = rawget(_G, MODULE_INTERNALS)
if not M then
    M = {
        ---------------- Common module attributes ----------------
        errinj = {
            ERRINJ_CFG = false,
            ERRINJ_FAILOVER_CHANGE_CFG = false,
            ERRINJ_RELOAD = false,
            ERRINJ_LONG_DISCOVERY = false,
        },
        -- Dictionary, key is router name, value is a router.
        routers = {},
        -- Router object which can be accessed by old api:
        -- e.g. vshard.router.call(...)
        static_router = nil,
        -- This counter is used to restart background fibers with
        -- new reloaded code.
        module_version = 0,
    }
end

--
-- Router object attributes.
--
local ROUTER_TEMPLATE = {
        -- Name of router.
        name = nil,
        -- The last passed configuration.
        current_cfg = nil,
        -- Time to outdate old objects on reload.
        connection_outdate_delay = nil,
        -- Bucket map cache.
        route_map = {},
        -- All known replicasets used for bucket re-balancing
        replicasets = nil,
        -- Fiber to maintain replica connections.
        failover_fiber = nil,
        -- Fiber to discovery buckets in background.
        discovery_fiber = nil,
        -- Bucket count stored on all replicasets.
        total_bucket_count = 0,
        -- Boolean lua_gc state (create periodic gc task).
        collect_lua_garbage = nil,
}

local STATIC_ROUTER_NAME = 'static_router'

-- Set a bucket to a replicaset.
local function bucket_set(router, bucket_id, rs_uuid)
    local replicaset = router.replicasets[rs_uuid]
    -- It is technically possible to delete a replicaset at the
    -- same time when route to the bucket is discovered.
    if not replicaset then
        return nil, lerror.vshard(lerror.code.NO_ROUTE_TO_BUCKET, bucket_id)
    end
    local old_replicaset = router.route_map[bucket_id]
    if old_replicaset ~= replicaset then
        if old_replicaset then
            old_replicaset.bucket_count = old_replicaset.bucket_count - 1
        end
        replicaset.bucket_count = replicaset.bucket_count + 1
    end
    router.route_map[bucket_id] = replicaset
    return replicaset
end

-- Remove a bucket from the cache.
local function bucket_reset(router, bucket_id)
    local replicaset = router.route_map[bucket_id]
    if replicaset then
        replicaset.bucket_count = replicaset.bucket_count - 1
    end
    router.route_map[bucket_id] = nil
end

--------------------------------------------------------------------------------
-- Discovery
--------------------------------------------------------------------------------

-- Search bucket in whole cluster
local function bucket_discovery(router, bucket_id)
    local replicaset = router.route_map[bucket_id]
    if replicaset ~= nil then
        return replicaset
    end

    log.verbose("Discovering bucket %d", bucket_id)
    local last_err = nil
    local unreachable_uuid = nil
    for uuid, _ in pairs(router.replicasets) do
        -- Handle reload/reconfigure.
        replicaset = router.replicasets[uuid]
        if replicaset then
            local _, err =
                replicaset:callrw('vshard.storage.bucket_stat', {bucket_id})
            if err == nil then
                return bucket_set(router, bucket_id, replicaset.uuid)
            elseif err.code ~= lerror.code.WRONG_BUCKET then
                last_err = err
                unreachable_uuid = uuid
            end
        end
    end
    local err = nil
    if last_err then
        if last_err.type == 'ClientError' and
           last_err.code == box.error.NO_CONNECTION then
            err = lerror.vshard(lerror.code.UNREACHABLE_REPLICASET,
                                unreachable_uuid, bucket_id)
        else
            err = lerror.make(last_err)
        end
    else
        -- All replicasets were scanned, but a bucket was not
        -- found anywhere, so most likely it does not exist. It
        -- can be wrong, if rebalancing is in progress, and a
        -- bucket was found to be RECEIVING on one replicaset, and
        -- was not found on other replicasets (it was sent during
        -- discovery).
        err = lerror.vshard(lerror.code.NO_ROUTE_TO_BUCKET, bucket_id)
    end

    return nil, err
end

-- Resolve bucket id to replicaset uuid
local function bucket_resolve(router, bucket_id)
    local replicaset, err
    local replicaset = router.route_map[bucket_id]
    if replicaset ~= nil then
        return replicaset
    end
    -- Replicaset removed from cluster, perform discovery
    replicaset, err = bucket_discovery(router, bucket_id)
    if replicaset == nil then
        return nil, err
    end
    return replicaset
end

--
-- Background fiber to perform discovery. It periodically scans
-- replicasets one by one and updates route_map.
--
local function discovery_f(router)
    local module_version = M.module_version
    while module_version == M.module_version do
        while not next(router.replicasets) do
            lfiber.sleep(consts.DISCOVERY_INTERVAL)
        end
        local old_replicasets = router.replicasets
        for rs_uuid, replicaset in pairs(router.replicasets) do
            local active_buckets, err =
                replicaset:callro('vshard.storage.buckets_discovery', {},
                                  {timeout = 2})
            while M.errinj.ERRINJ_LONG_DISCOVERY do
                M.errinj.ERRINJ_LONG_DISCOVERY = 'waiting'
                lfiber.sleep(0.01)
            end
            -- Renew replicasets object captured by the for loop
            -- in case of reconfigure and reload events.
            if router.replicasets ~= old_replicasets then
                break
            end
            if not active_buckets then
                log.error('Error during discovery %s: %s', replicaset, err)
            else
                if #active_buckets ~= replicaset.bucket_count then
                    log.info('Updated %s buckets: was %d, became %d',
                             replicaset, replicaset.bucket_count,
                             #active_buckets)
                end
                replicaset.bucket_count = #active_buckets
                for _, bucket_id in pairs(active_buckets) do
                    local old_rs = router.route_map[bucket_id]
                    if old_rs and old_rs ~= replicaset then
                        old_rs.bucket_count = old_rs.bucket_count - 1
                    end
                    router.route_map[bucket_id] = replicaset
                end
            end
            lfiber.sleep(consts.DISCOVERY_INTERVAL)
        end
    end
end

--
-- Immediately wakeup discovery fiber if exists.
--
local function discovery_wakeup(router)
    if router.discovery_fiber then
        router.discovery_fiber:wakeup()
    end
end

--------------------------------------------------------------------------------
-- API
--------------------------------------------------------------------------------

-- Perform shard operation
-- Function will restart operation after wrong bucket response until timeout
-- is reached
--
local function router_call(router, bucket_id, mode, func, args, opts)
    if opts and (type(opts) ~= 'table' or
                 (opts.timeout and type(opts.timeout) ~= 'number')) then
        error('Usage: call(bucket_id, mode, func, args, opts)')
    end
    local timeout = opts and opts.timeout or consts.CALL_TIMEOUT_MIN
    local replicaset, err
    local tend = lfiber.time() + timeout
    if bucket_id > router.total_bucket_count or bucket_id <= 0 then
        error('Bucket is unreachable: bucket id is out of range')
    end
    local call
    if mode == 'read' then
        call = 'callro'
    else
        call = 'callrw'
    end
    repeat
        replicaset, err = bucket_resolve(router, bucket_id)
        if replicaset then
::replicaset_is_found::
            local storage_call_status, call_status, call_error =
                replicaset[call](replicaset, 'vshard.storage.call',
                                 {bucket_id, mode, func, args},
                                 {timeout = tend - lfiber.time()})
            if storage_call_status then
                if call_status == nil and call_error ~= nil then
                    return call_status, call_error
                else
                    return call_status
                end
            end
            err = call_status
            if err.code == lerror.code.WRONG_BUCKET then
                bucket_reset(router, bucket_id)
                if err.destination then
                    replicaset = router.replicasets[err.destination]
                    if not replicaset then
                        log.warn('Replicaset "%s" was not found, but received'..
                                 ' from storage as destination - please '..
                                 'update configuration', err.destination)
                        -- Try to wait until the destination
                        -- appears. A destination can disappear,
                        -- if reconfiguration had been started,
                        -- and while is not executed on router,
                        -- but already is executed on storages.
                        while lfiber.time() <= tend do
                            lfiber.sleep(0.05)
                            replicaset = router.replicasets[err.destination]
                            if replicaset then
                                goto replicaset_is_found
                            end
                        end
                    else
                        replicaset = bucket_set(router, bucket_id, replicaset.uuid)
                        lfiber.yield()
                        -- Protect against infinite cycle in a
                        -- case of broken cluster, when a bucket
                        -- is sent on two replicasets to each
                        -- other.
                        if replicaset and lfiber.time() <= tend then
                            goto replicaset_is_found
                        end
                    end
                    return nil, err
                end
            elseif err.code == lerror.code.TRANSFER_IS_IN_PROGRESS then
                -- Do not repeat write requests, even if an error
                -- is not timeout - these requests are repeated in
                -- any case on client, if error.
                assert(mode == 'write')
                bucket_reset(router, bucket_id)
                return nil, err
            elseif err.code == lerror.code.NON_MASTER then
                -- Same, as above - do not wait and repeat.
                assert(mode == 'write')
                log.warn("Replica %s is not master for replicaset %s anymore,"..
                         "please update configuration!",
                          replicaset.master.uuid, replicaset.uuid)
                return nil, err
            else
                return nil, err
            end
        end
        lfiber.yield()
    until lfiber.time() > tend
    if err then
        return nil, err
    else
        local _, boxerror = pcall(box.error, box.error.TIMEOUT)
        return nil, lerror.box(boxerror)
    end
end

--
-- Wrappers for router_call with preset mode.
--
local function router_callro(router, bucket_id, ...)
    return router_call(router, bucket_id, 'read', ...)
end

local function router_callrw(router, bucket_id, ...)
    return router_call(router, bucket_id, 'write', ...)
end

--
-- Get replicaset object by bucket identifier.
-- @param bucket_id Bucket identifier.
-- @retval Netbox connection.
--
local function router_route(router, bucket_id)
    if type(bucket_id) ~= 'number' then
        error('Usage: router.route(bucket_id)')
    end
    return bucket_resolve(router, bucket_id)
end

--
-- Return map of all replicasets.
-- @retval See self.replicasets map.
--
local function router_routeall(router)
    return router.replicasets
end

--------------------------------------------------------------------------------
-- Failover
--------------------------------------------------------------------------------

local function failover_ping_round(router)
    for _, replicaset in pairs(router.replicasets) do
        local replica = replicaset.replica
        if replica ~= nil and replica.conn ~= nil and
           replica.down_ts == nil then
            if not replica.conn:ping({timeout = 5}) then
                log.info('Ping error from %s: perhaps a connection is down',
                         replica)
                -- Connection hangs. Recreate it to be able to
                -- fail over to a replica next by priority.
                replica.conn:close()
                replicaset:connect_replica(replica)
            end
        end
    end
end

--
-- Replicaset must fall its replica connection to lower priority,
-- if the current one is down too long.
--
local function failover_need_down_priority(replicaset, curr_ts)
    local r = replicaset.replica
    if r and r.down_ts then
        assert(not r:is_connected())
    end
    return r and r.down_ts and
           curr_ts - r.down_ts >= consts.FAILOVER_DOWN_TIMEOUT
           and r.next_by_priority
end

--
-- Once per FAILOVER_UP_TIMEOUT a replicaset must try to connect
-- to a replica with a higher priority.
--
local function failover_need_up_priority(replicaset, curr_ts)
    local up_ts = replicaset.replica_up_ts
    return not up_ts or curr_ts - up_ts >= consts.FAILOVER_UP_TIMEOUT
end

--
-- Collect UUIDs of replicasets, priority of whose replica
-- connections must be updated.
--
local function failover_collect_to_update(router)
    local ts = lfiber.time()
    local uuid_to_update = {}
    for uuid, rs in pairs(router.replicasets) do
        if failover_need_down_priority(rs, ts) or
           failover_need_up_priority(rs, ts) then
            table.insert(uuid_to_update, uuid)
        end
    end
    return uuid_to_update
end

--
-- Detect not optimal or disconnected replicas. For not optimal
-- try to update them to optimal, and down priority of
-- disconnected replicas.
-- @retval true A replica of an replicaset has been changed.
--
local function failover_step(router)
    failover_ping_round(router)
    local uuid_to_update = failover_collect_to_update(router)
    if #uuid_to_update == 0 then
        return false
    end
    local curr_ts = lfiber.time()
    local replica_is_changed = false
    for _, uuid in pairs(uuid_to_update) do
        local rs = router.replicasets[uuid]
        if M.errinj.ERRINJ_FAILOVER_CHANGE_CFG then
            rs = nil
            M.errinj.ERRINJ_FAILOVER_CHANGE_CFG = false
        end
        if rs == nil then
            log.info('Configuration has changed, restart failovering')
            lfiber.yield()
            return true
        end
        local old_replica = rs.replica
        if failover_need_up_priority(rs, curr_ts) then
            rs:up_replica_priority()
        end
        if failover_need_down_priority(rs, curr_ts) then
            rs:down_replica_priority()
        end
        if old_replica ~= rs.replica then
            log.info('New replica %s for %s', rs.replica, rs)
            replica_is_changed = true
        end
    end
    return replica_is_changed
end

--
-- Failover background function. Replica connection is the
-- connection to the nearest available server. Replica connection
-- is hold for each replicaset. This function periodically scans
-- replicasets and their replica connections. And some of them
-- appear to be disconnected or connected not to optimal replica.
--
-- If a connection is disconnected too long (more than
-- FAILOVER_DOWN_TIMEOUT), this function tries to connect to the
-- server with the lower priority. Priorities are specified in
-- weight matrix in config.
--
-- If a current replica connection has no the highest priority,
-- then this function periodically (once per FAILOVER_UP_TIMEOUT)
-- tries to reconnect to the best replica. When the connection is
-- established, it replaces the original replica.
--
local function failover_f(router)
    local module_version = M.module_version
    local min_timeout = math.min(consts.FAILOVER_UP_TIMEOUT,
                                 consts.FAILOVER_DOWN_TIMEOUT)
    -- This flag is used to avoid logging like:
    -- 'All is ok ... All is ok ... All is ok ...'
    -- each min_timeout seconds.
    local prev_was_ok = false
    while module_version == M.module_version do
::continue::
        local ok, replica_is_changed = pcall(failover_step, router)
        if not ok then
            log.error('Error during failovering: %s',
                      lerror.make(replica_is_changed))
            replica_is_changed = true
        elseif not prev_was_ok then
            log.info('All replicas are ok')
        end
        prev_was_ok = not replica_is_changed
        local logf
        if replica_is_changed then
            logf = log.info
        else
            -- In any case it is necessary to periodically log
            -- failover heartbeat.
            logf = log.verbose
        end
        logf('Failovering step is finished. Schedule next after %f seconds',
             min_timeout)
        lfiber.sleep(min_timeout)
    end
end

--------------------------------------------------------------------------------
-- Configuration
--------------------------------------------------------------------------------

-- Types of configuration.
CFG_NEW = 'new'
CFG_RELOAD = 'reload'
CFG_RECONFIGURE = 'reconfigure'

local function router_cfg(router, cfg, cfg_type)
    local vshard_cfg, box_cfg = lcfg.check(cfg, router.current_cfg)
    if cfg_type == CFG_NEW then
        log.info('Starting router configuration')
    else
        log.info('Starting router reconfiguration')
    end
    local new_replicasets = lreplicaset.buildall(vshard_cfg)
    local total_bucket_count = vshard_cfg.bucket_count
    log.info("Calling box.cfg()...")
    for k, v in pairs(box_cfg) do
        log.info({[k] = v})
    end
    -- It is considered that all possible errors during cfg
    -- process occur only before this place.
    -- This check should be placed as late as possible.
    if M.errinj.ERRINJ_CFG then
        error('Error injection: cfg')
    end
    box.cfg(box_cfg)
    log.info("Box has been configured")
    -- Move connections from an old configuration to a new one.
    -- It must be done with no yields to prevent usage both of not
    -- fully moved old replicasets, and not fully built new ones.
    lreplicaset.rebind_replicasets(new_replicasets, router.replicasets)
    -- Now the new replicasets are fully built. Can establish
    -- connections and yield.
    for _, replicaset in pairs(new_replicasets) do
        replicaset:connect_all()
    end
    lreplicaset.wait_masters_connect(new_replicasets)
    lreplicaset.outdate_replicasets(router.replicasets,
                                    vshard_cfg.connection_outdate_delay)
    router.connection_outdate_delay = vshard_cfg.connection_outdate_delay
    router.total_bucket_count = total_bucket_count
    router.collect_lua_garbage = vshard_cfg.collect_lua_garbage
    router.current_cfg = vshard_cfg
    router.replicasets = new_replicasets
    -- Update existing route map in-place.
    local old_route_map = router.route_map
    router.route_map = {}
    for bucket, rs in pairs(old_route_map) do
        router.route_map[bucket] = router.replicasets[rs.uuid]
    end
    if router.failover_fiber == nil then
        router.failover_fiber = util.reloadable_fiber_create(
            'vshard.failover.' .. router.name, M, 'failover_f', router)
    end
    if router.discovery_fiber == nil then
        router.discovery_fiber = util.reloadable_fiber_create(
            'vshard.discovery.' .. router.name, M, 'discovery_f', router)
    end
end

local function updage_lua_gc_state()
    local gc_active = false
    for _, xrouter in pairs(M.routers) do
        if xrouter.collect_lua_garbage then
            gc_active = true
        end
    end
    lua_gc.set_state(gc_active, consts.COLLECT_LUA_GARBAGE_INTERVAL)
end

--------------------------------------------------------------------------------
-- Bootstrap
--------------------------------------------------------------------------------

local function cluster_bootstrap(router)
    local replicasets = {}
    for uuid, replicaset in pairs(router.replicasets) do
        table.insert(replicasets, replicaset)
        local count, err = replicaset:callrw('vshard.storage.buckets_count',
                                             {})
        if count == nil then
            return nil, err
        end
        if count > 0 then
            return nil, lerror.vshard(lerror.code.NON_EMPTY)
        end
    end
    lreplicaset.calculate_etalon_balance(router.replicasets,
                                         router.total_bucket_count)
    local bucket_id = 1
    for uuid, replicaset in pairs(router.replicasets) do
        if replicaset.etalon_bucket_count > 0 then
            local ok, err =
                replicaset:callrw('vshard.storage.bucket_force_create',
                                  {bucket_id, replicaset.etalon_bucket_count})
            if not ok then
                return nil, err
            end
            local next_bucket_id = bucket_id + replicaset.etalon_bucket_count
            log.info('Buckets from %d to %d are bootstrapped on "%s"',
                     bucket_id, next_bucket_id - 1, uuid)
            bucket_id = next_bucket_id
        end
    end
    return true
end

--------------------------------------------------------------------------------
-- Monitoring
--------------------------------------------------------------------------------

--
-- Collect info about a replicaset's replica with a specified
-- name. Found alerts are appended to @an alerts table, if a
-- replica does not exist or is unavailable. In a case of error
-- @a errcolor is returned, and GREEN else.
--
local function replicaset_instance_info(replicaset, name, alerts, errcolor,
                                        errcode_unreachable, params1,
                                        errcode_missing, params2)
    local info = {}
    local replica = replicaset[name]
    if replica then
        info.uri = replica:safe_uri()
        info.uuid = replica.uuid
        info.network_timeout = replica.net_timeout
        if replica:is_connected() then
            info.status = 'available'
        else
            info.status = 'unreachable'
            if errcode_unreachable then
                table.insert(alerts, lerror.alert(errcode_unreachable,
                                                  unpack(params1)))
                return info, errcolor
            end
        end
    else
        info.status = 'missing'
        if errcode_missing then
            table.insert(alerts, lerror.alert(errcode_missing, unpack(params2)))
            return info, errcolor
        end
    end
    return info, consts.STATUS.GREEN
end

local function router_info(router)
    local state = {
        replicasets = {},
        bucket = {
            available_ro = 0,
            available_rw = 0,
            unreachable = 0,
            unknown = 0,
        },
        alerts = {},
        status = consts.STATUS.GREEN,
    }
    local bucket_info = state.bucket
    local known_bucket_count = 0
    for rs_uuid, replicaset in pairs(router.replicasets) do
        -- Replicaset info parameters:
        -- * master instance info;
        -- * replica instance info;
        -- * replicaset uuid.
        --
        -- Instance info parameters:
        -- * uri;
        -- * uuid;
        -- * status - available, unreachable, missing;
        -- * network_timeout - timeout for requests, updated on
        --   each 10 success and 2 failed requests. The greater
        --   timeout, the worse network feels itself.
        local rs_info = {
            uuid = replicaset.uuid,
            bucket = {}
        }
        state.replicasets[replicaset.uuid] = rs_info

        -- Build master info.
        local info, color =
            replicaset_instance_info(replicaset, 'master', state.alerts,
                                     consts.STATUS.ORANGE,
                                     -- Master exists, but not
                                     -- available.
                                     lerror.code.UNREACHABLE_MASTER,
                                     {replicaset.uuid, 'disconnected'},
                                     -- Master does not exists.
                                     lerror.code.MISSING_MASTER,
                                     {replicaset.uuid})
        state.status = math.max(state.status, color)
        rs_info.master = info

        -- Build replica info.
        if replicaset.replica ~= replicaset.master then
            info = replicaset_instance_info(replicaset, 'replica', state.alerts)
        end
        rs_info.replica = info
        if not replicaset.replica or
           (replicaset.replica and
            replicaset.replica ~= replicaset.priority_list[1]) then
            -- If the replica is not optimal, then some replicas
            -- possibly are down.
            local a = lerror.alert(lerror.code.SUBOPTIMAL_REPLICA,
                                   replicaset.uuid)
            table.insert(state.alerts, a)
            state.status = math.max(state.status, consts.STATUS.YELLOW)
        end

        if rs_info.replica.status ~= 'available' and
           rs_info.master.status ~= 'available' then
            local a = lerror.alert(lerror.code.UNREACHABLE_REPLICASET,
                                   replicaset.uuid)
            table.insert(state.alerts, a)
            state.status = consts.STATUS.RED
        end

        -- Bucket info consists of three parameters:
        -- * available_ro: how many buckets are known and
        --                 available for read requests;
        -- * available_rw: how many buckets are known and
        --                 available for both read and write
        --                 requests;
        -- * unreachable: how many buckets are known, but are not
        --                available for any requests;
        -- * unknown: how many buckets are unknown - a router
        --            doesn't know their replicasets.
        known_bucket_count = known_bucket_count + replicaset.bucket_count
        if rs_info.master.status ~= 'available' then
            if rs_info.replica.status ~= 'available' then
                rs_info.bucket.unreachable = replicaset.bucket_count
                bucket_info.unreachable = bucket_info.unreachable +
                                          replicaset.bucket_count
            else
                rs_info.bucket.available_ro = replicaset.bucket_count
                bucket_info.available_ro = bucket_info.available_ro +
                                           replicaset.bucket_count
            end
        else
            rs_info.bucket.available_rw = replicaset.bucket_count
            bucket_info.available_rw = bucket_info.available_rw +
                                       replicaset.bucket_count
        end
        -- No necessarity to update color - it is done above
        -- during replicaset master and replica checking.
        -- If a bucket is unreachable, then replicaset is
        -- unreachable too and color already is red.
    end
    bucket_info.unknown = router.total_bucket_count - known_bucket_count
    if bucket_info.unknown > 0 then
        state.status = math.max(state.status, consts.STATUS.YELLOW)
        table.insert(state.alerts, lerror.alert(lerror.code.UNKNOWN_BUCKETS,
                                                bucket_info.unknown))
    end
    return state
end

--
-- Build info about each bucket. Since a bucket map can be huge,
-- the function provides API to get not entire bucket map, but a
-- part.
-- @param offset Offset in a bucket map to select from.
-- @param limit Maximal bucket count in output.
-- @retval Map of type {bucket_id = 'unknown'/replicaset_uuid}.
--
local function router_buckets_info(router, offset, limit)
    if offset ~= nil and type(offset) ~= 'number' or
       limit ~= nil and type(limit) ~= 'number' then
        error('Usage: buckets_info(offset, limit)')
    end
    offset = offset or 0
    limit = limit or router.total_bucket_count
    local ret = {}
    -- Use one string memory for all unknown buckets.
    local available_rw = 'available_rw'
    local available_ro = 'available_ro'
    local unknown = 'unknown'
    local unreachable = 'unreachable'
    -- Collect limit.
    local first = math.max(1, offset + 1)
    local last = math.min(offset + limit, router.total_bucket_count)
    for bucket_id = first, last do
        local rs = router.route_map[bucket_id]
        if rs then
            if rs.master and rs.master:is_connected() then
                ret[bucket_id] = {uuid = rs.uuid, status = available_rw}
            elseif rs.replica and rs.replica:is_connected() then
                ret[bucket_id] = {uuid = rs.uuid, status = available_ro}
            else
                ret[bucket_id] = {uuid = rs.uuid, status = unreachable}
            end
        else
            ret[bucket_id] = {status = unknown}
        end
    end
    return ret
end

--------------------------------------------------------------------------------
-- Other
--------------------------------------------------------------------------------

local function router_bucket_id(router, key)
    if key == nil then
        error("Usage: vshard.router.bucket_id(key)")
    end
    return lhash.key_hash(key) % router.total_bucket_count + 1
end

local function router_bucket_count(router)
    return router.total_bucket_count
end

local function router_sync(router, timeout)
    if timeout ~= nil and type(timeout) ~= 'number' then
        error('Usage: vshard.router.sync([timeout: number])')
    end
    for rs_uuid, replicaset in pairs(router.replicasets) do
        local status, err = replicaset:callrw('vshard.storage.sync', {timeout})
        if not status then
            -- Add information about replicaset
            err.replicaset = rs_uuid
            return nil, err
        end
    end
end

if M.errinj.ERRINJ_RELOAD then
    error('Error injection: reload')
end

--------------------------------------------------------------------------------
-- Managing router instances
--------------------------------------------------------------------------------

local function cfg_reconfigure(router, cfg)
    return router_cfg(router, cfg, CFG_RECONFIGURE)
end

local router_mt = {
    __index = {
        cfg = cfg_reconfigure;
        info = router_info;
        buckets_info = router_buckets_info;
        call = router_call;
        callro = router_callro;
        callrw = router_callrw;
        route = router_route;
        routeall = router_routeall;
        bucket_id = router_bucket_id;
        bucket_count = router_bucket_count;
        sync = router_sync;
        bootstrap = cluster_bootstrap;
        bucket_discovery = bucket_discovery;
        discovery_wakeup = discovery_wakeup;
    }
}

-- Table which represents this module.
local module = {}

local function export_static_router_attributes()
    -- This metatable bypasses calls to a module to the static_router.
    local module_mt = {__index = {}}
    for method_name, method in pairs(router_mt.__index) do
        module_mt.__index[method_name] = function(...)
            if M.static_router then
                return method(M.static_router, ...)
            else
                error('Static router is not configured')
            end
        end
    end
    setmetatable(module, module_mt)
    -- Make static_router attributes accessible form
    -- vshard.router.internal.
    local M_static_router_attributes = {
        name = true,
        replicasets = true,
        route_map = true,
        total_bucket_count = true,
    }
    setmetatable(M, {
        __index = function(M, key)
            return M.static_router[key]
        end
    })
end

local function router_new(name, cfg)
    assert(type(name) == 'string' and type(cfg) == 'table',
           'Wrong argument type. Usage: vshard.router.new(name, cfg).')
    if M.routers[name] then
        return nil, string.format('Router with name %s already exists', name)
    end
    local router = table.deepcopy(ROUTER_TEMPLATE)
    setmetatable(router, router_mt)
    router.name = name
    M.routers[name] = router
    if name == STATIC_ROUTER_NAME then
        M.static_router = router
        export_static_router_attributes()
    end
    router_cfg(router, cfg, CFG_NEW)
    updage_lua_gc_state()
    return router
end

local function legacy_cfg(cfg)
    if M.static_router then
        -- Reconfigure.
        router_cfg(M.static_router, cfg, CFG_RECONFIGURE)
    else
        -- Create new static instance.
        router_new(STATIC_ROUTER_NAME, cfg)
    end
end

--------------------------------------------------------------------------------
-- Module definition
--------------------------------------------------------------------------------
--
-- About functions, saved in M, and reloading see comment in
-- storage/init.lua.
--
if not rawget(_G, MODULE_INTERNALS) then
    rawset(_G, MODULE_INTERNALS, M)
else
    for _, router in pairs(M.routers) do
        router_cfg(router, router.current_cfg, CFG_RELOAD)
        setmetatable(router, router_mt)
    end
    updage_lua_gc_state()
    M.module_version = M.module_version + 1
end

M.discovery_f = discovery_f
M.failover_f = failover_f
M.router_mt = router_mt
if M.static_router then
    export_static_router_attributes()
end

module.cfg = legacy_cfg
module.new = router_new
module.internal = M
module.module_version = function() return M.module_version end

return module
