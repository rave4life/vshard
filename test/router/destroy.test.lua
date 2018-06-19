test_run = require('test_run').new()
netbox = require('net.box')
fiber = require('fiber')

REPLICASET_1 = { 'storage_1_a', 'storage_1_b' }
REPLICASET_2 = { 'storage_2_a', 'storage_2_b' }

test_run:create_cluster(REPLICASET_1, 'storage')
test_run:create_cluster(REPLICASET_2, 'storage')
util = require('util')
util.wait_master(test_run, REPLICASET_1, 'storage_1_a')
util.wait_master(test_run, REPLICASET_2, 'storage_2_a')
test_run:cmd("create server router_1 with script='router/router_1.lua'")
test_run:cmd("start server router_1")

_ = test_run:cmd("switch router_1")
util = require('util')
fiber = require('fiber')
test_run:cmd("setopt delimiter ';'")
function wait_fibers_exit()
    while #util.vshard_fiber_list() > 0 do
        fiber.sleep(0.05)
    end
end;
test_run:cmd("setopt delimiter ''");

-- Validate destroy finction by fiber_list.
-- Netbox fibers are deleted after replicas by GC.
util.vshard_fiber_list()
vshard.router.destroy()
wait_fibers_exit()
vshard.router.cfg(cfg)
util.vshard_fiber_list()

_ = test_run:cmd("switch default")
test_run:cmd('stop server router_1')
test_run:cmd('cleanup server router_1')
test_run:drop_cluster(REPLICASET_2)
