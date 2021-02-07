# TODO

* check if we missed time (busy computing) when checking 
  min-wait-time / min-down-time.
* subscribe to interfaces, keep interface numbers up-to-date
* cleanup nodes after a config change check all limits
* Make Magic fixed size 8?, add feature flags (32 bit)
* Magic:16/binary, Features:32/unsigned
* Add Lat:32/float, Long:32/float to announce header if routing.type = location
* Add 0:32/float, 0:32/float to announce header if routing.type = blind
* Add Speed:32/float, 0:32/float for static/blind
* Add DeltaLat:32/float, DeltaLong:32/float for direction speed km/h
* Add DestLat:32/float, DestLong:32/float for current destination (if known)
* Add TNodeID:32/binary, CacheTimeout:32 (seconds)
  Cache Location/Destination indexed by TNodeID (temporary ID)
  for max CacheTimeout (s) (Forwarding information)
