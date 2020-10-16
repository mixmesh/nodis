# TODO

* Keep track on nodes in nodes in variouse states

Define up, pending and down as three groups where
each group as a limit on how man nodes that can join
say max 10 nodes up at any time, and max 100 nodes
pending to be served and 1000 nodes down that we
keep track on if they have recently been served.
A node that is up can be marked to wait on a wait list
so that pending nodes may be served.

.* MAX\_UP\_NODES = 10
 A node stays in up state until it has been served
 and marked as waiting or node stops pining and is
 marked as down

.* MAX\_PENDING\_NODES = 100
 A node will be pending and queued until 
 there is a slot among nodes in up state,
 that is when node_count(up) < MAX\_UP\_NODES
 A node can be marked to wait

.* MAX\_DOWN\_NODES = 2000
 A node that does not send timely pings will be considered
 in a down state. And can come from up, pending and wait states
 When a node response again it will be moved to pending state

.* MAX\_WAIT\_NODES = 1000
 After node has been served it can be marked to
 wait, until it can be served again. Then node
 will be put in pending state.

## State diagram 

    up -> wait | down
    pending -> up | down
    wait -> down | pending
    down -> pending

- pending nodes are moved to up state in a queue LIFO
- nodes are removed from down state after MAX\_DOWN\_TIME after
 they are regareded as fresh new if node appear again.
- nodes on wait list are moved to pending state after MAX\_WAIT\_TIME
that is a 'refresh' time interval when it can be expected that a node
may have more infomation to sync.

 
