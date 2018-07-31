test_run = require('test_run').new()

git_util = require('lua_libs.git_util')
util = require('lua_libs.util')
vshard_copy_path = util.BUILDDIR .. '/test/var/vshard_git_tree_copy'
evolution_log = git_util.log_hashes({args='vshard/storage/reload_evolution.lua', dir=util.SOURCEDIR})
-- Cleanup the directory after a previous build.
_ = os.execute('rm -rf ' .. vshard_copy_path)
-- 1. `git worktree` cannot be used because PACKPACK mounts
-- `/source/` in `ro` mode.
-- 2. Just `cp -rf` cannot be used due to a little different
-- behavior in Centos 7.
_ = os.execute('mkdir ' .. vshard_copy_path)
_ = os.execute("cd " .. util.SOURCEDIR .. ' && cp -rf `ls -A --ignore=build` ' .. vshard_copy_path)
-- Checkout the first commit with a reload_evolution mechanism.
git_util.exec_cmd({cmd='checkout', args='-f', dir=vshard_copy_path})
git_util.exec_cmd({cmd='checkout', args=evolution_log[#evolution_log] .. '~1', dir=vshard_copy_path})

REPLICASET_1 = { 'storage_1_a', 'storage_1_b' }
REPLICASET_2 = { 'storage_2_a', 'storage_2_b' }
test_run:create_cluster(REPLICASET_1, 'reload_evolution')
test_run:create_cluster(REPLICASET_2, 'reload_evolution')
util = require('lua_libs.util')
util.wait_master(test_run, REPLICASET_1, 'storage_1_a')
util.wait_master(test_run, REPLICASET_2, 'storage_2_a')

test_run:switch('storage_1_a')
vshard.storage.bucket_force_create(1, vshard.consts.DEFAULT_BUCKET_COUNT / 2)
bucket_id_to_move = vshard.consts.DEFAULT_BUCKET_COUNT

test_run:switch('storage_2_a')
fiber = require('fiber')
vshard.storage.bucket_force_create(vshard.consts.DEFAULT_BUCKET_COUNT / 2 + 1, vshard.consts.DEFAULT_BUCKET_COUNT / 2)
bucket_id_to_move = vshard.consts.DEFAULT_BUCKET_COUNT
vshard.storage.internal.reload_version
wait_rebalancer_state('The cluster is balanced ok', test_run)
box.space.test:insert({42, bucket_id_to_move})

test_run:switch('default')
git_util.exec_cmd({cmd='checkout', args=evolution_log[1], dir=vshard_copy_path})

test_run:switch('storage_2_a')
package.loaded['vshard.storage'] = nil
vshard.storage = require("vshard.storage")
test_run:grep_log('storage_2_a', 'vshard.storage.reload_evolution: upgraded to') ~= nil
vshard.storage.internal.reload_version
-- Make sure storage operates well.
vshard.storage.bucket_force_drop(2000)
vshard.storage.bucket_force_create(2000)
vshard.storage.buckets_info()[2000]
vshard.storage.call(bucket_id_to_move, 'read', 'do_select', {42})
vshard.storage.bucket_send(bucket_id_to_move, replicaset1_uuid)
vshard.storage.garbage_collector_wakeup()
fiber = require('fiber')
while box.space._bucket:get({bucket_id_to_move}) do fiber.sleep(0.01) end
test_run:switch('storage_1_a')
vshard.storage.bucket_send(bucket_id_to_move, replicaset2_uuid)
test_run:switch('storage_2_a')
vshard.storage.call(bucket_id_to_move, 'read', 'do_select', {42})
-- Check info() does not fail.
vshard.storage.info() ~= nil

--
-- Send buckets to create a disbalance. Wait until the rebalancer
-- repairs it. Similar to `tests/rebalancer/rebalancer.test.lua`.
--
vshard.storage.rebalancer_disable()
move_start = vshard.consts.DEFAULT_BUCKET_COUNT / 2 + 1
move_cnt = 100
assert(move_start + move_cnt < vshard.consts.DEFAULT_BUCKET_COUNT)
for i = move_start, move_start + move_cnt - 1 do box.space._bucket:delete{i} end
box.space._bucket.index.status:count({vshard.consts.BUCKET.ACTIVE})
test_run:switch('storage_1_a')
move_start = vshard.consts.DEFAULT_BUCKET_COUNT / 2 + 1
move_cnt = 100
vshard.storage.bucket_force_create(move_start, move_cnt)
box.space._bucket.index.status:count({vshard.consts.BUCKET.ACTIVE})
test_run:switch('storage_2_a')
vshard.storage.rebalancer_enable()
wait_rebalancer_state('Rebalance routes are sent', test_run)
wait_rebalancer_state('The cluster is balanced ok', test_run)
box.space._bucket.index.status:count({vshard.consts.BUCKET.ACTIVE})

test_run:switch('default')
test_run:drop_cluster(REPLICASET_2)
test_run:drop_cluster(REPLICASET_1)
test_run:cmd('clear filter')
