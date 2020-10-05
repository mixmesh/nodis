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
	
