# eotl_reserved_slots

This is a TF2 sourcemod plugin I wrote for the [EOTL](https://www.endofthelinegaming.com/) community.

This plugin implements reserved slots for VIPs.  When a vip is connecting to the server and the server is full it will kicked a non-VIP to make space.

This does not work like other reserved slots plugins that do 31/32 or 32/33 players, allowing anyone to join, then kicking non-vips after the fact.  Instead during the pre-connect phase of a new client, the vip/full server check is done.  If the incoming client a vip and server is full it will instantly kick a non-vip to make space, allowing the VIP's connection process to proceed.  In the event server is full of vips, the incoming vip will get a "You are a VIP, but server is full of VIPs" message instead of the normal server full message.

The plugin also implements seed immunity for non-vips.  ie: if a non-vip helps seed the server up to a threshhold they will be immune from being kicked.

### Dependencies
<hr>

This plugin depends on eotl_vip_core plugin.


### Say Commands
<hr>

**!rsi**

This will display details about how many vips, non-vip immune, and kickable clients are on the server.

### ConVars
<hr>

**eotl_reserved_slots_preauth_time [seconds]**

When I client is connected there is a period of time before the client's steamID is authorized by the game/steam.  Before this happens we won't know the steamID of the client and thus can't verify they are a VIP.  This setting the maximum amount of time we will wait for the client's steamID to authorize. During this preauth time the client is immune from being kicked.

Default: 20

**eotl_reserved_slots_seed_immunity_threshold [num]**

If a non-vip joins when less then equal to this many players on the server, they will be immune from being kicked for reserved slots.  The default value is geared towards a 32 player server.

Default: 19

**eotl_reserved_slots_seed_immunity_interval [seconds]**

How often to check if a non-vip should have immunity.  Because of how tf2 works, when a map change happens all players effectively disconnect and reconnect to the server.  This makes it difficult to determine the number of actual players on the servers during map change.  This timer will kick off and run every [seconds] seconds after a map change to check if any non-vips should have immunity.

Default: 60

**eotl_reserved_slots_seed_immunity_time [seconds]**

This option provides a way for seed immunity to persist after a server crash and/or a immune non-vip player disconnects.  When a player has seed immunity and there are **more** then seed_immunity_threshold players on the server, the plugin will save the current time to a config file (configs/eotl_reserved_slots.dat) at the end of each round.

When a non-vip player joins the server, if their saved time + the [seconds] value from this cvar are greater then the current time, the player is automatically re-given immunity.

Default: 1800 (30 minutes)

**eotl_reserved_slots_debug [0/1]**

Enable additional debug logging.

Default: 0 (disabled)