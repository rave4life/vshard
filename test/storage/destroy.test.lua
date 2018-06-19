test_run = require('test_run').new()

REPLICASET_1 = { 'storage_1_a', 'storage_1_b' }
REPLICASET_2 = { 'storage_2_a', 'storage_2_b' }

test_run:create_cluster(REPLICASET_1, 'storage')
test_run:create_cluster(REPLICASET_2, 'storage')
util = require('util')
util.wait_master(test_run, REPLICASET_1, 'storage_1_a')
util.wait_master(test_run, REPLICASET_2, 'storage_2_a')

_ = test_run:cmd("switch storage_1_a")
util = require('util')
fiber = require('fiber')
test_run:cmd("setopt delimiter ';'")
function wait_fibers_exit()
    while #util.vshard_fiber_list() > 0 do
        fiber.sleep(0.05)
    end
end;
test_run:cmd("setopt delimiter ''");

-- Storage is configured.
-- Establish net.box connection.
_, rs = next(vshard.storage.internal.replicasets)
rs:callro('echo', {'some data'})
rs = nil
-- Validate destroy finction by fiber_list.
-- Netbox fibers are deleted after replicas by GC.
util.vshard_fiber_list()
box.schema.user.exists('storage') == true
box.space._bucket ~= nil
-- Destroy storage.
vshard.storage.destroy()
wait_fibers_exit()
box.space._bucket == nil

-- Reconfigure storage.
-- gh-52: Allow use existing user.
box.schema.user.exists('storage') == true
vshard.storage.cfg(cfg, names['storage_1_a'])
_, rs = next(vshard.storage.internal.replicasets)
rs:callro('echo', {'some data'})
rs = nil
box.space._bucket ~= nil
util.vshard_fiber_list()

_ = test_run:cmd("switch default")
test_run:drop_cluster(REPLICASET_2)
test_run:drop_cluster(REPLICASET_1)
