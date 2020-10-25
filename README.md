# nodis - Node discovery over ip multicast


# nodis demo over ipv6

On laptop

    erl -nodis device '"wlx00c0ca928061"' family inet6 -s nodis
	
On red & black nodes

	erl -nodis device '"wlan0"' family inet6 -s nodis


From laptop 

	nodis:i().
	nodis:subscribe().
	
alternat suspend the red and black nodes and check for messages
also shutdown to get down messages.

	flush().

## States

The neigbour nodes to nodis can have state **up**, **down**, **pending** or **wait**.
The state diagram looks like follow:

    up -> wait | down
    pending -> up | down
    wait -> down | pending
    down -> pending 

The number of neighbours that can be in any of the state are controlled
by the following configurables

* max-up-nodes  (10)

 A node stays in up state until it has been served
 and marked as waiting (using **nodis:wait(Addr)**) or if node stops 
 pinging and is  marked as **down**

* max-pending-nodes (100)

 A node will be pending and queued until 
 there is a slot among nodes in up state,
 that is when node_count(up) < max-up-nodes

* max-wait-nodes ( 1000 )

 The node must then wait **min-wait-time** before it become
 pending again. The subscriber will receive a up message
 when the node is **up** again.

* max-down-nodes ( 2000 )

 A node that does not send timely pings will be considered
 in a down state. Nodes may in down state must wait at least **min-down-time** 
 ms before it can be activated again, put on pending list.

