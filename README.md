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