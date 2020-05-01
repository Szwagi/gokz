#include <sourcemod>

#include <dhooks>

#include <movementapi>
#include <gokz/anticheat>
#include <gokz/core>
#include <gokz/replays>

#include <autoexecconfig>

#undef REQUIRE_EXTENSIONS
#undef REQUIRE_PLUGIN
#include <gokz/localdb>
#include <sourcebanspp>
#include <updater>

#pragma newdecls required
#pragma semicolon 1



public Plugin myinfo = 
{
	name = "GOKZ Anti-Cheat", 
	author = "DanZay", 
	description = "Detects basic player movement cheats", 
	version = GOKZ_VERSION, 
	url = "https://bitbucket.org/kztimerglobalteam/gokz"
};

#define UPDATER_URL GOKZ_UPDATER_BASE_URL..."gokz-anticheat.txt"

bool gB_GOKZLocalDB;
bool gB_SourceBansPP;
bool gB_SourceBans;

Handle gH_DHooks_OnTeleport;

int gI_CmdNum[MAXPLAYERS + 1];
int gI_LastOriginTeleportCmdNum[MAXPLAYERS + 1];

int gI_ButtonCount[MAXPLAYERS + 1];
int gI_ButtonsIndex[MAXPLAYERS + 1];
int gI_Buttons[MAXPLAYERS + 1][AC_MAX_BUTTON_SAMPLES];

int gI_BhopCount[MAXPLAYERS + 1];
int gI_BhopIndex[MAXPLAYERS + 1];
int gI_BhopLastTakeoffCmdnum[MAXPLAYERS + 1];
int gI_BhopLastRecordedBhopCmdnum[MAXPLAYERS + 1];
bool gB_BhopHitPerf[MAXPLAYERS + 1][AC_MAX_BHOP_SAMPLES];
int gI_BhopPreJumpInputs[MAXPLAYERS + 1][AC_MAX_BHOP_SAMPLES];
int gI_BhopPostJumpInputs[MAXPLAYERS + 1][AC_MAX_BHOP_SAMPLES];
bool gB_BhopPostJumpInputsPending[MAXPLAYERS + 1];
bool gB_LastLandingWasValid[MAXPLAYERS + 1];

ConVar gCV_gokz_autoban;
ConVar gCV_gokz_autoban_duration_bhop_hack;
ConVar gCV_gokz_autoban_duration_bhop_macro;
ConVar gCV_sv_autobunnyhopping;

#include "gokz-anticheat/api.sp"
#include "gokz-anticheat/bhop_tracking.sp"
#include "gokz-anticheat/commands.sp"



// =====[ PLUGIN EVENTS ]=====

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	CreateNatives();
	RegPluginLibrary("gokz-anticheat");
	return APLRes_Success;
}

public void OnPluginStart()
{
	LoadTranslations("common.phrases");
	LoadTranslations("gokz-common.phrases");
	LoadTranslations("gokz-anticheat.phrases");
	
	CreateConVars();
	CreateGlobalForwards();
	HookEvents();
	RegisterCommands();
}

public void OnAllPluginsLoaded()
{
	if (LibraryExists("updater"))
	{
		Updater_AddPlugin(UPDATER_URL);
	}
	gB_GOKZLocalDB = LibraryExists("gokz-localdb");
	gB_SourceBansPP = LibraryExists("sourcebans++");
	gB_SourceBans = LibraryExists("sourcebans");
	
	for (int client = 1; client <= MaxClients; client++)
	{
		if (IsClientInGame(client))
		{
			OnClientPutInServer(client);
		}
	}
}

public void OnLibraryAdded(const char[] name)
{
	if (StrEqual(name, "updater"))
	{
		Updater_AddPlugin(UPDATER_URL);
	}
	gB_GOKZLocalDB = gB_GOKZLocalDB || StrEqual(name, "gokz-localdb");
	gB_SourceBansPP = gB_SourceBansPP || StrEqual(name, "sourcebans++");
	gB_SourceBans = gB_SourceBans || StrEqual(name, "sourcebans");
}

public void OnLibraryRemoved(const char[] name)
{
	gB_GOKZLocalDB = gB_GOKZLocalDB && !StrEqual(name, "gokz-localdb");
	gB_SourceBansPP = gB_SourceBansPP && !StrEqual(name, "sourcebans++");
	gB_SourceBans = gB_SourceBans && !StrEqual(name, "sourcebans");
}



// =====[ CLIENT EVENTS ]=====

public void OnClientPutInServer(int client)
{
	OnClientPutInServer_BhopTracking(client);
	HookClientEvents(client);
}

public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon, int &subtype, int &cmdnum, int &tickcount, int &seed, int mouse[2])
{
	gI_CmdNum[client] = cmdnum;
	return Plugin_Continue;
}

public void OnPlayerRunCmdPost(int client, int buttons, int impulse, const float vel[3], const float angles[3], int weapon, int subtype, int cmdnum, int tickcount, int seed, const int mouse[2])
{
	if (!IsPlayerAlive(client) || IsFakeClient(client))
	{
		return;
	}
	
	OnPlayerRunCmdPost_BhopTracking(client, buttons, cmdnum);
}

public MRESReturn DHooks_OnTeleport(int client, Handle params)
{
	// Parameter 1 not null means origin affected
	gI_LastOriginTeleportCmdNum[client] = !DHookIsNullParam(params, 1) ? gI_CmdNum[client] : gI_LastOriginTeleportCmdNum[client];
	
	// Parameter 3 not null means velocity affected
	//gI_LastVelocityTeleportCmdNum[client] = !DHookIsNullParam(params, 3) ? gI_CmdNum[client] : gI_LastVelocityTeleportCmdNum[client];
	
	return MRES_Ignored;
}

public void GOKZ_OnFirstSpawn(int client)
{
	GOKZ_PrintToChat(client, false, "%t", "Anti-Cheat Warning");
}

public void GOKZ_AC_OnPlayerSuspected(int client, ACReason reason, const char[] notes, const char[] stats)
{
	LogSuspicion(client, reason, notes, stats);
}



// =====[ PUBLIC ]=====

void SuspectPlayer(int client, ACReason reason, const char[] notes, const char[] stats)
{
	Call_OnPlayerSuspected(client, reason, notes, stats);

	GOKZ_Suspected(client);
	
	if (gB_GOKZLocalDB)
	{
		GOKZ_DB_SetCheater(client, true);
	}
	
	if (gCV_gokz_autoban.BoolValue)
	{
		BanSuspect(client, reason);
	}
}



// =====[ PRIVATE ]=====

static void CreateConVars()
{
	AutoExecConfig_SetFile("gokz-anticheat", "sourcemod/gokz");
	AutoExecConfig_SetCreateFile(true);
	
	gCV_gokz_autoban = AutoExecConfig_CreateConVar(
		"gokz_autoban", 
		"1", 
		"Whether to autoban players when they are suspected of cheating.", 
		_, 
		true, 
		0.0, 
		true, 
		1.0);
	
	gCV_gokz_autoban_duration_bhop_hack = AutoExecConfig_CreateConVar(
		"gokz_autoban_duration_bhop_hack", 
		"0", 
		"Duration of anticheat autobans for bunnyhop hacking in minutes (0 for permanent).", 
		_, 
		true, 
		0.0);
	
	gCV_gokz_autoban_duration_bhop_macro = AutoExecConfig_CreateConVar(
		"gokz_autoban_duration_bhop_macro", 
		"43200",  // 30 days
		"Duration of anticheat autobans for bunnyhop macroing in minutes (0 for permanent).", 
		_, 
		true, 
		0.0);
	
	AutoExecConfig_ExecuteFile();
	AutoExecConfig_CleanFile();
	
	gCV_sv_autobunnyhopping = FindConVar("sv_autobunnyhopping");
}

static void HookEvents()
{
	GameData gameData = new GameData("sdktools.games");
	int offset;
	
	// Setup DHooks OnTeleport for players
	offset = gameData.GetOffset("Teleport");
	gH_DHooks_OnTeleport = DHookCreate(offset, HookType_Entity, ReturnType_Void, ThisPointer_CBaseEntity, DHooks_OnTeleport);
	DHookAddParam(gH_DHooks_OnTeleport, HookParamType_VectorPtr);
	DHookAddParam(gH_DHooks_OnTeleport, HookParamType_ObjectPtr);
	DHookAddParam(gH_DHooks_OnTeleport, HookParamType_VectorPtr);
	DHookAddParam(gH_DHooks_OnTeleport, HookParamType_Bool);
	
	delete gameData;
}

static void HookClientEvents(int client)
{
	DHookEntity(gH_DHooks_OnTeleport, true, client);
}

static void LogSuspicion(int client, ACReason reason, const char[] notes, const char[] stats)
{
	char logPath[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, logPath, sizeof(logPath), AC_LOG_PATH);
	
	switch (reason)
	{
		case ACReason_BhopHack:LogToFileEx(logPath, "%L was suspected of bhop hacking. Notes - %s, Stats - %s", client, notes, stats);
		case ACReason_BhopMacro:LogToFileEx(logPath, "%L was suspected of bhop macroing. Notes - %s, Stats - %s", client, notes, stats);
	}
}

static void BanSuspect(int client, ACReason reason)
{
	switch (reason)
	{
		case ACReason_BhopHack:
		{
			AutoBanClient(
				client, 
				gCV_gokz_autoban_duration_bhop_hack.IntValue, 
				"gokz-anticheat - Bhop hacking", 
				"You have been banned for using a bhop hack");
		}
		case ACReason_BhopMacro:
		{
			AutoBanClient(
				client, 
				gCV_gokz_autoban_duration_bhop_macro.IntValue, 
				"gokz-anticheat - Bhop macroing", 
				"You have been banned for using a bhop macro");
		}
	}
}

static void AutoBanClient(int client, int minutes, const char[] reason, const char[] kickMessage)
{
	if (gB_SourceBansPP)
	{
		SBPP_BanPlayer(0, client, minutes, reason);
	}
	else if (gB_SourceBans)
	{
		SBBanPlayer(0, client, minutes, reason);
	}
	else
	{
		BanClient(client, minutes, BANFLAG_AUTO, reason, kickMessage, "gokz-anticheat", 0);
	}
} 