#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <clientprefs>
#define AUTOLOAD_EXTENSIONS
#define REQUIRE_EXTENSIONS
#include <connect>
#include "../eotl_vip_core/eotl_vip_core.inc"

#define PLUGIN_AUTHOR         "ack"
#define PLUGIN_VERSION        "2.01"

#define RSI_CONFIG_FILE       "configs/eotl_reserved_slots.dat"

#define RETRY_LOADVIPMAP_TIME 10.0

public Plugin myinfo = {
	name = "eotl_reserved_slots",
	author = PLUGIN_AUTHOR,
	description = "reserved slots for vips",
	version = PLUGIN_VERSION,
	url = ""
};

enum struct PlayerState {
    bool isPreAuth;         // when a client is connected, but steam id isn't auth'd yet
    int preAuthTimeStart;   // debug
    bool isImmune;
    bool kicking;
}

// globals
PlayerState g_playerStates[MAXPLAYERS + 1];
StringMap g_vipMap;
StringMap g_seedImmunityMap;
ConVar g_cvDebug;
ConVar g_cvPreAuthTime;
ConVar g_cvSeedImmunityThreshold;
ConVar g_cvSeedImmunityInterval;
ConVar g_cvSeedImmunityTime;
KeyValues g_rsiTimes;
bool g_roundOver;
char g_rsiTimesFile [128];

public void OnPluginStart() {
    LogMessage("version %s starting", PLUGIN_VERSION);
    g_cvDebug = CreateConVar("eotl_reserved_slots_debug", "0", "0/1 enable debug output", FCVAR_NONE, true, 0.0, true, 1.0);
    g_cvPreAuthTime = CreateConVar("eotl_reserved_slots_preauth_time", "20", "how long in seconds to allow a client to auth their steamID", FCVAR_NONE, true, 1.0);
    g_cvSeedImmunityThreshold = CreateConVar("eotl_reserved_slots_seed_immunity_threshold", "19", "if non-vip joins when less then this many players on the server, they will be immune from being kicked", FCVAR_NONE);
    g_cvSeedImmunityInterval = CreateConVar("eotl_reserved_slots_seed_immunity_interval", "60", "how often in seconds to see if players should get seed immunity", FCVAR_NONE, true, 15.0);
    g_cvSeedImmunityTime = CreateConVar("eotl_reserved_slots_seed_immunity_time", "1800", "time in seconds immune player is allowed reconnect and still have immunity", FCVAR_NONE, true, 0.0);

    char error[256];
    if(GetExtensionFileStatus("connect.ext", error, sizeof(error)) != 1) {
        SetFailState("Required extension \"connect\" failed: %s", error);
    }
    g_seedImmunityMap = CreateTrie();

    BuildPath(Path_SM, g_rsiTimesFile, sizeof(g_rsiTimesFile), "%s", RSI_CONFIG_FILE);

    HookEvent("player_team", EventPlayerTeam);
    HookEvent("teamplay_round_start", EventRoundStart, EventHookMode_PostNoCopy);
    HookEvent("teamplay_round_stalemate", EventRoundEnd, EventHookMode_PostNoCopy);
    HookEvent("teamplay_round_win", EventRoundEnd, EventHookMode_PostNoCopy);
    HookEvent("teamplay_game_over", EventRoundEnd, EventHookMode_PostNoCopy);

    RegConsoleCmd("sm_rsi", CommandRSI);
}

public void OnMapStart() {

    for(int client = 1;client <= MaxClients; client++) {
        g_playerStates[client].isPreAuth = false;
        g_playerStates[client].isImmune = false;
        g_playerStates[client].kicking = false;
    }

    g_roundOver = false;
    g_vipMap = CreateTrie();

    LoadRSITimes();

    // Its impossible get a count of players during map change
    // since everyone does a disconnect/connect, which takes the
    // server down to 0 players.  So we are just using a timer
    // to periodically check if non-vips should get immunity.
    CreateTimer(g_cvSeedImmunityInterval.FloatValue, CheckImmunityTimer, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

public void OnMapEnd() {
    CloseHandle(g_vipMap);
    CloseHandle(g_rsiTimes);
}

public void OnClientAuthorized(int client, const char[] auth) {

    g_playerStates[client].isPreAuth = false;
    if(IsClientSourceTV(client)) {
        LogMessage("OnClientAuthorized %N (%s) is sourcetv", client, auth);
        return;
    }

    if(IsFakeClient(client)) {
        return;
    }

    int diff = GetTime() - g_playerStates[client].preAuthTimeStart;
    LogDebug("OnClientAuthorized %N (%s) took %d seconds to auth", client, auth, diff);

    if(EotlIsSteamIDVip(auth)) {
        LogMessage("OnClientAuthorized %N (%s) is a vip", client, auth);
        return;
    }
    LogMessage("OnClientAuthorized %N (%s) is NOT a vip", client, auth);

    // user already flagged as immune
    int junk;
    if(GetTrieValue(g_seedImmunityMap, auth, junk)) {
        g_playerStates[client].isImmune = true;
        LogMessage("OnClientAuthorized %N (%s) has kick immunity for seeding", client, auth);
    }
}

public void OnClientCookiesCached(int client) {

    if(IsClientSourceTV(client)) {
        return;
    }

    if(IsFakeClient(client)) {
        return;
    }

    if(EotlIsClientVip(client)) {
        return;
    }

    if(g_playerStates[client].isImmune) {
        return;
    }

    if(CheckRSITime(client)) {
        g_playerStates[client].isImmune = true;
        LogMessage("OnClientCookiesCached: client: %N giving kick immunity for previous seeding (rsi time)", client);
    }
}

public Action EventRoundStart(Handle event, const char[] name, bool dontBroadcast) {
    g_roundOver = false;
    return Plugin_Continue;
}

public Action EventRoundEnd(Handle event, const char[] name, bool dontBroadcast) {

    if(g_roundOver) {
        return Plugin_Continue;
    }
    g_roundOver = true;

    int client_count = GetClientCount(false);
    if(client_count > g_cvSeedImmunityThreshold.IntValue) {
        LogDebug("EventRoundEnd: updating rsi times");
        UpdateRSITimes();
    } else {
        LogDebug("EventRoundEnd: not updating rsi times because not enough players are on the server");
    }

    return Plugin_Continue;
}

// There doesnt seem to be a callback for failed client auth, so
// if the client isn't authed within g_cvPreAuthTime.FloatValue force clear
// the isPreAuth flag on them.
public Action ClientClearPreAuth(Handle timer, int client) {

    if(g_playerStates[client].isPreAuth) {
        LogDebug("ClientMaxAuthTime: %d force clearing isPreAuth", client);
        g_playerStates[client].isPreAuth = false;
    }
    return Plugin_Continue;
}

public void OnClientConnected(int client) {
    LogDebug("OnClientConnected: %d (%N) PreAuthTimer: %f", client, client, g_cvPreAuthTime.FloatValue);
    g_playerStates[client].isPreAuth = true;
    g_playerStates[client].isImmune = false;
    g_playerStates[client].kicking = false;
    g_playerStates[client].preAuthTimeStart = GetTime();

    CreateTimer(g_cvPreAuthTime.FloatValue, ClientClearPreAuth, client);
}

public void OnClientDisconnect(int client) {
    LogDebug("OnClientDisconnect: %d", client);
    g_playerStates[client].isPreAuth = false;
    g_playerStates[client].isImmune = false;
    g_playerStates[client].kicking = false;
}

// when a client actually disconnects from the server.  OnClientDisconnect
// gets called during map changes, which we dont want.
public Action EventClientRealDisconnect(Handle event, const char[] name, bool dontBroadcast) {
    char steam2[32], steam3[32];

    // event is giving us steamv3 id but we track everything in steam2
    // so we need to convert
    GetEventString(event, "networkid", steam3, sizeof(steam3), "");
    if(Steam3ToSteam2(steam3, steam2, sizeof(steam2))) {
        if(RemoveFromTrie(g_seedImmunityMap, steam2)) {
           LogMessage("EventClientRealDisconnect: removed %s from seed immunity", steam2);
        }
    }

    return Plugin_Continue;
}

public Action EventPlayerTeam(Handle event, const char[] name, bool dontBroadcast) {
    int client = GetClientOfUserId(GetEventInt(event, "userid"));

    if(IsFakeClient(client)) {
        return Plugin_Continue;
    }

    if(EotlIsClientVip(client)) {
        return Plugin_Continue;
    }

    // don't broadcast immunity stuff its its not even viable
    if(g_cvSeedImmunityThreshold.IntValue <= 0 || g_cvSeedImmunityThreshold.IntValue >= MaxClients) {
        return Plugin_Continue;
    }

    if(g_playerStates[client].isImmune) {
        PrintToChat(client, "\x01[\x03VIP\x01] You have been given reserved slot kick immunity for helping seed the server. If you are having fun, please consider becoming a VIP \x03https://www.endofthelinegaming.com/vip/\x01");
    } else {
        PrintToChat(client, "\x01[\x03VIP\x01] You can get reserved slot kick immunity if you join the server when there are less then %d players on", g_cvSeedImmunityThreshold.IntValue);
    }

    return Plugin_Continue;
}

// Its unclear if a race condition can happen here if the server is 31/32 and 2
// clients connect at the same time.  Can OnClientPreConnectEx() be called for
// both clients before either of them have been fully connected?
public bool OnClientPreConnectEx(const char[] name, char password[255], const char[] ip, const char[] steamID, char rejectReason[255]) {

    if(!EotlIsSteamIDVip(steamID)) {
        LogDebug("PreConnect: %s (%s) is not vip, ignoring", name, steamID);
        return true;
    }

    LogDebug("PreConnect: %s (%s) is a vip", name, steamID);

    int clients = 0;
    int immunes = 0;
    int vips = 0;
    int preauth = 0;
    int kickable = 0;
    int kicking = 0;
    int stv = 0;
    for(int client = 1;client <= MaxClients;client++) {
        if(!IsClientConnected(client)) {
            continue;
        }

        clients++;

        if(IsClientSourceTV(client)) {
            stv++;
        } else if(IsFakeClient(client)) {
            kickable++;
        } else if(EotlIsClientVip(client)) {
            vips++;
        } else if(g_playerStates[client].isImmune) {
            immunes++;
        } else if(g_playerStates[client].isPreAuth) {
            preauth++;
        } else if(g_playerStates[client].kicking) {
            kicking++;
        } else {
            kickable++;
        }
    }

    LogDebug("PreConnect: %s (%s) clients %d/%d (%d vips, %d immunes, %d stv, %d preauth, %d kicking, %d kickable)", name, steamID, clients, MaxClients, vips, immunes, stv, preauth, kicking, kickable);
    if(clients < MaxClients) {
        LogDebug("PreConnect: %s (%s) empty slot available, ignoring", name, steamID);
        return true;
    }

    if(vips + immunes == MaxClients) {
        LogDebug("PreConnect: %s (%s) rejected VIP because server is full of VIPs", name, steamID);
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

        if(IsClientSourceTV(client)) {
            LogDebug("FindKickTarget: Skipping client %d, because client is sourceTV", client);
            continue;
        }

        if(IsFakeClient(client)) {
            LogDebug("FindKickTarget: Picked client %d because its a bot", client);
            return client;
        }

        if(g_playerStates[client].isImmune) {
            LogDebug("FindKickTarget: Skipping client %d, because of flag Immune", client);
            continue;
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

        if(!EotlIsClientVip(client)) {
            LogDebug("FindKickTarget: Picked client %d because they aren't a VIP", client);
            return client;
        }
    }
    LogMessage("FindKickTarget: No target found");
    return -1;
}

public Action CommandRSI(int caller, int args) {
    int clients = 0;
    int immunes = 0;
    int vips = 0;
    int kickable = 0;
    int stv = 0;

    for(int client = 1; client <= MaxClients;client++) {
        if(!IsClientConnected(client)) {
            continue;
        }

        clients++;

        if(IsClientSourceTV(client)) {
            stv++;
        } else if(IsFakeClient(client)) {
            kickable++;
        } else if(EotlIsClientVip(client)) {
            vips++;
        } else if(g_playerStates[client].isImmune) {
            immunes++;
        } else {
            kickable++;
        }
    }

    PrintToChat(caller, "\x01[\x03rsi\x01] clients %d/%d (%d vips, %d immunes, %d stv, %d kickable)", clients, MaxClients, vips, immunes, stv, kickable);
    PrintToChat(caller, "\x01[\x03rsi\x01] seed immunity threshold is <= %d players", g_cvSeedImmunityThreshold.IntValue);

    if(immunes == 0) {
        return Plugin_Continue;
    }

    PrintToChat(caller, "\x01[\x03rsi\x01] players with seed immunity");

    for(int client = 1; client <= MaxClients;client++) {
        if(!IsClientConnected(client)) {
            continue;
        }

        if(IsFakeClient(client)) {
            continue;
        }

        if(g_playerStates[client].isImmune) {
            PrintToChat(caller, "\x03  %N\x01", client);
        }
    }

    return Plugin_Continue;
}

public Action CheckImmunityTimer(Handle timer, int junk) {
    CheckImmunity();
    return Plugin_Continue;
}

void CheckImmunity() {

    int client_count = GetClientCount(false);
    if(client_count > g_cvSeedImmunityThreshold.IntValue) {
        return;
    }

    for(int client = 1; client <= MaxClients; client++) {
        if(!IsClientConnected(client)) {
            continue;
        }

        if(IsFakeClient(client)) {
            continue;
        }

        if(EotlIsClientVip(client)) {
            continue;
        }

        if(g_playerStates[client].isImmune) {
            continue;
        }

        char steamID[32];
        if(GetClientAuthId(client, AuthId_Steam2, steamID, sizeof(steamID))) {
            LogMessage("CheckImmunity: %N (%s) giving kick immunity for seeding", client, steamID);
            if(IsClientInGame(client)) {
                PrintToChat(client, "\x01[\x03VIP\x01] You have been given reserved slot kick immunity for helping seed the server. If you are having fun, please consider becoming a VIP \x03https://www.endofthelinegaming.com/vip/\x01");
            }
            SetTrieValue(g_seedImmunityMap, steamID, 1, true);
            g_playerStates[client].isImmune = true;
        }
    }
}

bool Steam3ToSteam2(const char[]steam3, char[]steam2, int maxlen) {

    if(StrEqual(steam3, "STEAM_ID_PENDING") || StrEqual(steam3, "BOT") || StrEqual(steam3, "UNKNOWN")) {
        return false;
    }

    int m_unAccountID = StringToInt(steam3[5]);
    int m_unMod = m_unAccountID % 2;
    Format(steam2, maxlen, "STEAM_0:%d:%d", m_unMod, (m_unAccountID-m_unMod)/2);
    return true;
}

void LoadRSITimes() {
    g_rsiTimes = CreateKeyValues("rsi");

    if(!FileToKeyValues(g_rsiTimes, g_rsiTimesFile)) {
        LogMessage("LoadRSITimes: failed to load %s, starting from scratch", g_rsiTimesFile);
        return;
    }

    int curTime = GetTime();
    bool needSave = false;
    char steamID[32];
    int rsiTime;
    LogDebug("LoadRSITimes:");

    g_rsiTimes.JumpToKey("rsi");
    if(!g_rsiTimes.GotoFirstSubKey()) {
        LogDebug("no saved rsi times");
        return;
    }

    // do a little cleanup while we load
    do {
            g_rsiTimes.GetSectionName(steamID, sizeof(steamID));
            rsiTime = g_rsiTimes.GetNum("rsiTime", 0);

            if(rsiTime > curTime) {
                LogDebug("  steamID: %s, rsiTime: %d is in the future? clamping to current time (%d)", steamID, rsiTime, curTime);
                rsiTime = curTime;
                needSave = true;
            } else if(rsiTime + g_cvSeedImmunityTime.IntValue < curTime) {
                LogDebug("  steamID: %s, rsiTime: %d is expired, removing", steamID, rsiTime);
                g_rsiTimes.DeleteThis();
                needSave = true;
            } else {
                LogDebug("  steamID: %s, rsiTime: %d", steamID, rsiTime);
            }
    } while(g_rsiTimes.GotoNextKey());

    if(needSave) {
        SaveRSITimes();
    }
}

void UpdateRSITimes() {
    int rsiTime = GetTime();
    bool needSave = false;
    char steamID[32];

    LogDebug("UpdateRSITimes:");
    for(int client = 1;client <= MaxClients; client++) {
        if(!IsClientConnected(client)) {
            continue;
        }

        if(IsFakeClient(client)) {
            continue;
        }

        if(EotlIsClientVip(client)) {
            continue;
        }

        if(!g_playerStates[client].isImmune) {
            continue;
        }

        if(!GetClientAuthId(client, AuthId_Steam2, steamID, sizeof(steamID))) {
            LogMessage("UpdateRSITimes: Failed to get steamId for client %N, skipping them", client);
            continue;
        }

        LogDebug("  steamID: %s (%N), rsiTime updated: %d", steamID, client, rsiTime);
        g_rsiTimes.Rewind();
        g_rsiTimes.JumpToKey(steamID, true);
        g_rsiTimes.SetNum("rsiTime", rsiTime);
        needSave = true;
    }

    if(needSave) {
        SaveRSITimes();
    }
}

void SaveRSITimes() {
    g_rsiTimes.Rewind();
    if(!g_rsiTimes.ExportToFile(g_rsiTimesFile)) {
        LogDebug("ERROR failed to save rsi times to %s", g_rsiTimesFile);
        return;
    }
    LogDebug("Saved rsi times");
}

bool CheckRSITime(int client) {
    char steamID[32];
    if(!GetClientAuthId(client, AuthId_Steam2, steamID, sizeof(steamID))) {
        LogMessage("CheckRSITime: failed to get steamId for client %N", client);
        return false;
    }

    g_rsiTimes.Rewind();
    if(!g_rsiTimes.JumpToKey(steamID)) {
        LogDebug("CheckRSITime: %N (%s) has no saved rsi time", client, steamID);
        return false;
    }

    int rsiTime = g_rsiTimes.GetNum("rsiTime", 0);

    LogDebug("CheckRSITime: client: %N, rsiTime: %d, GetTime: %d", client, rsiTime, GetTime());
    if(rsiTime + g_cvSeedImmunityTime.IntValue > GetTime()) {
        return true;
    }
    return false;
}

void LogDebug(char []fmt, any...) {

    if(!g_cvDebug.BoolValue) {
        return;
    }

    char message[128];
    VFormat(message, sizeof(message), fmt, 2);
    LogMessage(message);
}