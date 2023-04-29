# eotl_reserved_slots

This is a TF2 sourcemod plugin.

This plugin implements reserved slots for VIPs.  When a vip is connecting to the server and the server is full it will kicked a non-VIP to make space.

This does not work like other reserved slots plugins that do 31/32 or 32/33 players, allowing anyone to join, then kicking non-vips after the fact.  Instead during the pre-connect phase of a new client, the vip/full server check is done.  If its a vip and server is full it will instantly kick a non-vip to make space, allowing the VIP's connection process to proceed.  In the event server is full of vips, the incoming vip will get a "You are a VIP, but server is full of VIPs" message.

### Dependencies
<hr>

**Database**<br>

This plugin is expecting the following to exist (hardcoded as its what we need)

* Database config named 'default'
* Table on that database named 'vip_users'
* Columns in that table named 'streamID'

This information provides the plugin with a list of VIP's and their associated icon.

### ConVars
<hr>

**eotl_reserved_slots_seed_immunity_threshold [num]**

If non-vip joins when less then equal to this many players on the server, they will be immune from being kicked for reserved slots.

Default: 19

**eotl_reserved_slots_seed_immunity_interval [seconds]**

How often to check if a non-vip should have immunity.  Because of how tf2 works, when a map change happens all players effectively disconnect and reconnect to the server.  This makes it difficult to determine the number of actual players on the servers during map change.  This timer will kick off and run every [seconds] seconds after a map change to check if any non-vips should have immunity.

Default: 60

**eotl_reserved_slots_seed_immunity_time [seconds]**

This option provides a way for seed immunity to persist after a server crash and/or a player disconnecting.  When a player has seed immunity and there are *more* then seed immunity threshold players on the server, the plugin will save the current time to a client cookie every time an immune player changes teams (ie start of map / round).

When a player joins the server, if their saved time + the [seconds] value from this cvar are greater then the current time, the player is automatically given immunity.

Default: 1800 (30 minutes)

**eotl_reserved_slots_debug [0/1]**

Enable additional debug logging.

Default: 0 (disabled)