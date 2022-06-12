#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#define AUTOLOAD_EXTENSIONS
#define REQUIRE_EXTENSIONS
#include <connect>

#define PLUGIN_AUTHOR  "ack"
#define PLUGIN_VERSION "0.8"

#define DB_CONFIG      "default"
#define DB_TABLE       "vip_users"
#define DB_COL_STEAMID "steamID"

#define RETRY_LOADVIPMAP_TIME 10.0
#define PREAUTH_MAX_TIME      10.0

public Plugin myinfo = {
	name = "eotl_reserved_slots",
	author = PLUGIN_AUTHOR,
	description = "reserved slots for vips",
	version = PLUGIN_VERSION,
	url = ""
};

enum struct PlayerState {
    bool isPreAuth;         // when a client is connected, but steam id isn't auth'd yet
    bool isVip;
    bool kicking;
}

// globals
PlayerState g_playerStates[MAXPLAYERS + 1];
StringMap vipMap;
ConVar g_cvDebug;

public void OnPluginStart() {
    LogMessage("version %s starting (db config: %s, table: %s)", PLUGIN_VERSION, DB_CONFIG, DB_TABLE);
    g_cvDebug = CreateConVar("eotl_reserved_slots_debug", "0", "0/1 enable debug output", FCVAR_NONE, true, 0.0, true, 1.0);

    char error[256];
    if(GetExtensionFileStatus("connect.ext", error, sizeof(error)) != 1) {
        SetFailState("Required extension \"connect\" failed: %s", error);
    }

}

public void OnMapStart() {

    if(!SQL_CheckConfig(DB_CONFIG)) {
        SetFailState("Database config \"%s\" doesn't exist", DB_CONFIG);
    }

    for(int client = 1;client <= MaxClients; client++) {
        g_playerStates[client].isPreAuth = false;
        g_playerStates[client].isVip = false;
        g_playerStates[client].kicking = false;
    }

    vipMap = CreateTrie();

    if(!LoadVipMap()) {
        LogError("Database issue, will retry every %f seconds", RETRY_LOADVIPMAP_TIME);
        CreateTimer(RETRY_LOADVIPMAP_TIME, RetryLoadVipMap);
    }
}

public void OnMapEnd() {
    CloseHandle(vipMap);
}

public void OnClientAuthorized(int client, const char[] auth) {

    g_playerStates[client].isPreAuth = false;

    if(IsFakeClient(client)) {
        return;
    }

    int junk;
    if(GetTrieValue(vipMap, auth, junk)) {
        g_playerStates[client].isVip = true;
        LogMessage("OnClientAuthorized %N (%s) is a vip", client, auth);
    }
}

// There doesnt seem to be a callback for failed client auth, so
// if the client isn't authed within PREAUTH_MAX_TIME force clear
// the isPreAuth flag on them.
public Action ClientClearPreAuth(Handle timer, int client) {

    if(g_playerStates[client].isPreAuth) {
        LogDebug("ClientMaxAuthTime: %d force clearing isPreAuth", client);
        g_playerStates[client].isPreAuth = false;
    }
    return Plugin_Continue;
}

public void OnClientConnected(int client) {
    LogDebug("OnClientConnected: %d", client);
    g_playerStates[client].isPreAuth = true;
    g_playerStates[client].isVip = false;
    g_playerStates[client].kicking = false;

    CreateTimer(PREAUTH_MAX_TIME, ClientClearPreAuth, client);
}

public void OnClientDisconnect(int client) {
    LogDebug("OnClientDisconnect: %d", client);
    g_playerStates[client].isPreAuth = false;
    g_playerStates[client].isVip = false;
    g_playerStates[client].kicking = false;
}

// Its unclear if a race condition can happen here if the server is 31/32 and 2
// clients connect at the same time.  Can OnClientPreConnectEx() be called for
// both clients before either of them have been fully connected?
public bool OnClientPreConnectEx(const char[] name, char password[255], const char[] ip, const char[] steamID, char rejectReason[255]) {

    int junk;
    if(!GetTrieValue(vipMap, steamID, junk)) {
        LogDebug("PreConnect: %s (%s) is not vip, ignoring", name, steamID);
        return true;
    }

    LogDebug("PreConnect: %s (%s) is a vip", name, steamID);

    int clients = 0;
    int vips = 0;
    for(int client = 1;client <= MaxClients;client++) {
        if(IsClientConnected(client)) {
            clients++;
            if(g_playerStates[client].isVip) {
                vips++;
            }
        }
    }

    LogDebug("PreConnect: %s (%s) clients %d/%d (%d vips)", name, steamID, clients, MaxClients, vips);
    if(clients < MaxClients) {
        LogDebug("PreConnect: %s (%s) empty slot available, ignoring", name, steamID);
        return true;
    }

    if(vips == MaxClients) {
        LogMessage("PreConnect: %s (%s) rejected VIP because server is full of VIPs", name, steamID);
        strcopy(rejectReason, sizeof(rejectReason), "You are a VIP, but server is full of VIPs");
        return false;
    }

    LogDebug("PreConnect: %s (%s) server full, searching for someone to kick", name, steamID);

    int target = FindKickTarget();
    if(target > 0) {
        LogMessage("PreConnect: %s (%s) kicking client %d (%N) to make space", name, steamID, target, target);
        KickClientEx(target, "VIP Slot Reservation,  https://www.endofthelinegaming.com/vip/");
        g_playerStates[target].kicking = true;
        return true;
    }

    LogMessage("PreConnect: %s (%s) rejected the VIP because there is no one to kick", name, steamID);
    strcopy(rejectReason, sizeof(rejectReason), "You are a VIP, but server is full of VIPs");
    return false;
}

// for now just pick the first match
int FindKickTarget() {

    for(int client = 1;client <= MaxClients;client++) {

        if(IsFakeClient(client)) {
            LogDebug("FindKickTarget: Picked client %d because its a bot", client);
            return client;
        }

        // client already in the process of being kicked
        if(g_playerStates[client].kicking) {
            LogDebug("FindKickTarget: Skipping client %d, because of flag kicking", client);
            continue;
        }

        if(g_playerStates[client].isPreAuth) {
            LogDebug("FindKickTarget: Skipping client %d, because of flag PreAuth", client);
            continue;
        }

        if(!g_playerStates[client].isVip) {
            LogDebug("FindKickTarget: Picked client %d because they aren't a VIP", client);
            return client;
        }
    }
    LogMessage("FindKickTarget: No target found");
    return -1;
}

public Action RetryLoadVipMap(Handle timer) {
    if(!LoadVipMap()) {
        CreateTimer(RETRY_LOADVIPMAP_TIME, RetryLoadVipMap);
        return Plugin_Continue;
    }

    LogMessage("Setting up isVip for connected clients");
    char steamID[32];
    int junk;
    for(int client = 1;client <= MaxClients;client++) {
        if(!IsClientConnected(client) || IsFakeClient(client)) {
            continue;
        }

        if(GetClientAuthId(client, AuthId_Steam2, steamID, sizeof(steamID))) {
            if(GetTrieValue(vipMap, steamID, junk)) {
                LogMessage("%N (%s) is a vip", client, steamID);
                g_playerStates[client].isVip = true;
            }
        }
    }
    return Plugin_Continue;
}

// grab a list of vips (steamIDs) from the database and store them in a map
bool LoadVipMap() {
    Handle dbh;
    char error[256];

    dbh = SQL_Connect(DB_CONFIG, false, error, sizeof(error));
    if(dbh == INVALID_HANDLE) {
        LogError("LoadVipMap: connection to database failed (DB config: %s): %s", DB_CONFIG, error);
        return false;
    }

    char query[128];
    Format(query, sizeof(query), "SELECT %s from %s", DB_COL_STEAMID, DB_TABLE);

    DBResultSet results;
    results = SQL_Query(dbh, query);
    CloseHandle(dbh);

    // this seems to be an indication we aren't connected to the database
    if(results == INVALID_HANDLE) {
        LogError("LoadVipMap: SQL_Query returned INVALID_HANDLE. Something maybe wrong with the connection to the database");
        return false;
    }

    if(results.RowCount <= 0) {
        LogMessage("LoadVipMap: SQL_Query return no results!");
        CloseHandle(results);
        return true;
    }

    while(results.FetchRow()) {
        char steamID[32];
        if(results.FetchString(0, steamID, sizeof(steamID))) {
            SetTrieValue(vipMap, steamID, 1, true);
        }
    }

    LogMessage("Loaded %d vips from database", GetTrieSize(vipMap));
    CloseHandle(results);
    return true;
}

void LogDebug(char []fmt, any...) {

    if(!g_cvDebug.BoolValue) {
        return;
    }

    char message[128];
    VFormat(message, sizeof(message), fmt, 2);
    LogMessage(message);
}