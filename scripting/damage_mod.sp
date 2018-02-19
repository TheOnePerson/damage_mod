/*
	- Damage Modification -
	Written by almostagreatcoder (almostagreatcoder@web.de)

	Licensed under the GPLv3
	
	This program is free software: you can redistribute it and/or modify
	it under the terms of the GNU General Public License as published by
	the Free Software Foundation, either version 3 of the License, or
	(at your option) any later version.

	This program is distributed in the hope that it will be useful,
	but WITHOUT ANY WARRANTY; without even the implied warranty of
	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
	GNU General Public License for more details.

	You should have received a copy of the GNU General Public License
	along with this program.  If not, see <http://www.gnu.org/licenses/>.
	
	****

	Make sure that damage_mod.cfg is in your sourcemod/configs/ directory.
	You can set default damage reduction (or increasement) for players there.

	CVars:
		-
	
	Commands:
		sm_takedamage		// modify the receiving damage factor for any target
		sm_makedamage		// modify the inflicting damage factor for any target

*/

/**
 * TODO: Implement a command for reloading the config file (maybe, some tine...) and/or a status command
 */

// Uncomment the line below to get a whole bunch of PrintToServer debug messages...
//#define DEBUG

#pragma semicolon 1

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <clientprefs>
#include <adt_trie>

#define PLUGIN_NAME 		"Damage Modification"
#define PLUGIN_VERSION 		"0.1.2"
#define PLUGIN_AUTHOR 		"almostagreatcoder"
#define PLUGIN_DESCRIPTION 	"Enables modification of damage points for players"
#define PLUGIN_URL 			"https://forums.alliedmods.net/showthread.php?t=305408"

#define CONFIG_FILENAME 	"damage_mod.cfg"
#define MAX_PLAYERCONFIGS 100
#define TRANSLATIONS_FILENAME "damage_mod.phrases"
#define CHAT_COLORTAG1 		"\x0794D8E9"
#define CHAT_COLORTAG_NORM 	"\x01"

#define PLUGIN_LOGPREFIX 	"[Damage] "

#define STEAMID_LENGTH 25

#define COMMAND_TAKEDAMAGE "sm_takedamage"
#define COMMAND_MAKEDAMAGE "sm_makedamage"

#define CVAR_VERSION "sm_damage_version"
#define CVAR_ENABLED "sm_damage_enabled"

// Plugin definitions
public Plugin:myinfo = 
{
	name = PLUGIN_NAME, 
	author = PLUGIN_AUTHOR, 
	description = PLUGIN_DESCRIPTION, 
	version = PLUGIN_VERSION, 
	url = PLUGIN_URL
};

// cvar handles
new Handle:g_CvarEnabled = INVALID_HANDLE;

// global dynamic arrays
new Handle:g_ConfigPlayerSteamID = INVALID_HANDLE;		// array for steam ids of players in config file
new Handle:g_ConfigPlayerTakeDamage = INVALID_HANDLE;	// array for take damage factors (Float) of players in config file
new Handle:g_ConfigPlayerMakeDamage = INVALID_HANDLE;	// array for make damage factors (Float) of players in config file

// global static arrays
new Float:g_PlayerTakeDamageMultiplier[MAXPLAYERS + 1];		// array for storing damage multipliers of players
new Float:g_PlayerMakeDamageMultiplier[MAXPLAYERS + 1];		// array for storing damage multipliers of players

// other global vars
new String:g_LastError[255];					// needed for config file parsing and logging: holds the last error message
new g_SectionDepth;								// for config file parsing: keeps track of the nesting level of sections
new g_ConfigLine;								// for config file parsing: keeps track of the current line number
new Float:g_currentPlayerConfigTakeDamage;
new Float:g_currentPlayerConfigMakeDamage;
new String:g_currentPlayerConfigSteamID[STEAMID_LENGTH];

new bool:g_Enabled = true;
new Float:g_defaultTakeDamage;
new Float:g_defaultMakeDamage;

//
// Handlers for public events
//

public OnPluginStart() {
	
	LoadTranslations("common.phrases");
	LoadTranslations("core.phrases");
	LoadTranslations(TRANSLATIONS_FILENAME);
	
	g_ConfigPlayerSteamID = CreateArray(STEAMID_LENGTH);
	g_ConfigPlayerTakeDamage = CreateArray(sizeof(g_currentPlayerConfigTakeDamage));
	g_ConfigPlayerMakeDamage = CreateArray(sizeof(g_currentPlayerConfigMakeDamage));
	
	CreateConVar(CVAR_VERSION, PLUGIN_VERSION, "Damage Modification version", FCVAR_NOTIFY | FCVAR_REPLICATED | FCVAR_DONTRECORD | FCVAR_SPONLY);
	g_CvarEnabled = CreateConVar(CVAR_ENABLED, "1", "1 enables the Damage Modification plugin, 0 disables it.", FCVAR_NONE, true, 0.0, true, 1.0);
	
	RegAdminCmd(COMMAND_TAKEDAMAGE, PlayerCommandHandler, ADMFLAG_CUSTOM1, "Damage Modification: modify the damage points a player takes");
	RegAdminCmd(COMMAND_MAKEDAMAGE, PlayerCommandHandler, ADMFLAG_CUSTOM1, "Damage Modification: modify the damage points a player inflicts to others");
	
	g_defaultTakeDamage = 1.0;
	g_defaultMakeDamage = 1.0;
	
	// Hook cvar changes
	HookConVarChange(g_CvarEnabled, CVar_EnabledChanged);
	AutoExecConfig();
	
	// Hook events
	HookEvent( "player_activate", Event_PlayerActivate);

}

public OnPluginEnd() {
	// clear the stuff read from config file
	ResetConfigArray();
}

public void OnConfigsExecuted() {
	MyLoadConfig();
	decl i;
	for (i = 1; i <= MaxClients; i++)
		if (IsClientConnected(i) && !IsFakeClient(i))
			OnClientPostAdminCheck(i);
		else
			ResetPlayer(i);
}

/**
 * CVar handlers
 */
public CVar_EnabledChanged(Handle:cvar, const String:oldval[], const String:newval[]) {
	decl String:tag[50];
	if (strcmp(newval, "0") == 0) {
		g_Enabled = false;
		strcopy(tag, sizeof(tag), "CVarMessageEnabled");
	} else {
		g_Enabled = true;
		strcopy(tag, sizeof(tag), "CVarMessageDisabled");
	}
	PrintToChatAll("%s%t%s%t", CHAT_COLORTAG1, "ChatPrefix", CHAT_COLORTAG_NORM, tag);
}

/**
 * Handler for connecting clients
 */
public void OnClientPostAdminCheck(client) {
	if (client <= MaxClients && !IsFakeClient(client)) {
		ResetPlayer(client);
		decl String:steamID[STEAMID_LENGTH];
		new Float:damageFactors[2];
		GetClientAuthId(client, AuthId_Steam2, steamID, sizeof(steamID));
		GetFactorsToSteamID(steamID, damageFactors); 
		g_PlayerTakeDamageMultiplier[client] = damageFactors[0];
		g_PlayerMakeDamageMultiplier[client] = damageFactors[1];
		SDKHook(client, SDKHook_OnTakeDamage, OnPlayerTakeDamage);
#if defined DEBUG
		PrintToServer("%sConnecting client id %d: take_damage:%f, make_damage: %f", PLUGIN_LOGPREFIX, client, g_PlayerTakeDamageMultiplier[client], g_PlayerMakeDamageMultiplier[client]); // DEBUG
#endif
	}
}

/**
 * Clean up on disconnecting clients
 */
public void OnClientDisconnect(client) {
	if (client <= MaxClients) {
		ResetPlayer(client);
		SDKUnhook(client, SDKHook_OnTakeDamage, OnPlayerTakeDamage);
	}
}

/**
 * Event Handler for player_activate
 */
public Event_PlayerActivate(Event event, const String:eventName[], bool:dontBroadcast)
{
	new client = GetClientOfUserId(event.GetInt("userid"));
	if (0 < client <= MaxClients && IsClientInGame(client)) {
#if defined DEBUG
		PrintToServer("%s*** Event_PlayerActivate *** / client=%d", PLUGIN_LOGPREFIX, client);
#endif		
		SDKHook(client, SDKHook_OnTakeDamage, OnPlayerTakeDamage);
	}
}

/**
 * Event Handler for take damage
 */
public Action OnPlayerTakeDamage(victimId, &attackerId, &inflictorId, &Float:damage, &dmgType, &weapon, Float:vecDmgForce[3], Float:vecDmgPosition[3], dmgCustom )
{
	if (g_Enabled) {
		new Float:newdamage = damage;
		if (0 < victimId <= MaxClients)
			newdamage = newdamage * g_PlayerTakeDamageMultiplier[victimId];
		if (0 < attackerId <= MaxClients)
			newdamage = newdamage * g_PlayerMakeDamageMultiplier[attackerId];
		if (damage != newdamage) {
#if defined DEBUG
		
			PrintToServer("%s*** OnPlayerTakeDamage *** / userid=%d, attackerid=%d, damage_org=%f, damage_new=%d", PLUGIN_LOGPREFIX, victimId, attackerId, damage, RoundFloat(newdamage));
#endif
			damage = newdamage;
			return Plugin_Changed;
		} else 
			return Plugin_Continue;
	} else
		return Plugin_Continue;
}

/**
 * Read the config file
 */
 MyLoadConfig() {
	g_SectionDepth = 0;
	g_ConfigLine = 0;
	ResetConfigArray();
	new String:g_ConfigFile[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, g_ConfigFile, sizeof(g_ConfigFile), "configs/%s", CONFIG_FILENAME);
	
	g_LastError = "";
	new Handle:parser = SMC_CreateParser();
	SMC_SetReaders(parser, Config_NewSection, Config_KeyValue, Config_EndSection);
	SMC_SetParseEnd(parser, Config_End);
	SMC_SetRawLine(parser, Config_NewLine);
	SMC_ParseFile(parser, g_ConfigFile);
	CloseHandle(parser);
}

public SMCResult:Config_NewLine(Handle:parser, const char[] line, int lineno) {
	g_ConfigLine = lineno;
	return SMCParse_Continue;
}

public SMCResult:Config_NewSection(Handle:parser, const String:name[], bool:quotes) {
	new SMCResult:result = SMCParse_Continue;
	g_SectionDepth++;

	if (g_SectionDepth == 2) {
		// new player details group
		if (GetArraySize(g_ConfigPlayerSteamID) > MAX_PLAYERCONFIGS) {
			result = SMCParse_Halt;
			Format(g_LastError, sizeof(g_LastError), "Error in config file line %d: Number of player sections exceeds limit of %d", g_ConfigLine, MAX_PLAYERCONFIGS);
			LogError(g_LastError);
#if defined DEBUG
			PrintToServer("%s%s", PLUGIN_LOGPREFIX, g_LastError);
#endif
		} else {
			// store default for current section (are processed again at end of section)
			g_currentPlayerConfigTakeDamage = g_defaultTakeDamage;
			g_currentPlayerConfigMakeDamage = g_defaultMakeDamage;
			g_currentPlayerConfigSteamID = "";
		}
	}	// (ignore any other section nesting level...)
	return result;
}

public SMCResult:Config_KeyValue(Handle:parser, const String:key[], const String:value[], bool:key_quotes, bool:value_quotes) {
	new SMCResult:result = SMCParse_Continue;
	if (2 <= g_SectionDepth <= 3) {
		// Level 2 = player values
		if (strcmp(key, "TakeDamage", false) == 0) {
			if (g_SectionDepth == 2)
				g_currentPlayerConfigTakeDamage = StringToFloat(value);
			else
				g_defaultTakeDamage = StringToFloat(value);
		} else if (strcmp(key, "MakeDamage", false) == 0) {
			if (g_SectionDepth == 2)
				g_currentPlayerConfigMakeDamage = StringToFloat(value);
			else
				g_defaultMakeDamage = StringToFloat(value);
		} else if (strcmp(key, "SteamID", false) == 0) {
			if (strcmp(value, "Default", false) == 0) {
				// Default values set
				g_SectionDepth = 3;
			} else {
				g_SectionDepth = 2;
				strcopy(g_currentPlayerConfigSteamID, sizeof(g_currentPlayerConfigSteamID), value);
			}
		}
	}
	return result;
}

public SMCResult:Config_EndSection(Handle:parser) {
	new SMCResult:result = SMCParse_Continue;
	if (g_SectionDepth == 2) {
		// player's details group ending
		PushArrayString(g_ConfigPlayerSteamID, g_currentPlayerConfigSteamID);
		PushArrayCell(g_ConfigPlayerTakeDamage, g_currentPlayerConfigTakeDamage);
		PushArrayCell(g_ConfigPlayerMakeDamage, g_currentPlayerConfigMakeDamage);
	}
	g_SectionDepth--;
	if (g_SectionDepth == 2) 
		g_SectionDepth--;
	return result;
}

public Config_End(Handle:parser, bool:halted, bool:failed) {
	if (halted)
		LogError("Configuration parsing stopped!");
	if (failed)
		LogError("Configuration parsing failed!");
}

/**
 * Handler for all commands that can affect more than one target.
 * 
 * @param client 	client id
 * @args			Arguments given for the command
 *
 */
public Action:PlayerCommandHandler(client, args) {
	new commandType = 0;
	// determine command
	decl String:strTarget[MAX_NAME_LENGTH];
	GetCmdArg(0, strTarget, sizeof(strTarget));
	if (strcmp(strTarget, COMMAND_TAKEDAMAGE, false) == 0) {
		commandType = 1;	// define take damage
		if (args != 2) {
			ReplyToCommand(client, "%t", "CommandReplyTakeDamage", strTarget, strTarget);
			return Plugin_Handled;
		}
	} else {
		commandType = 0;	// define make damage
		if (args != 2) {
			ReplyToCommand(client, "%t", "CommandReplyMakeDamage", strTarget, strTarget);
			return Plugin_Handled;
		}
	}
	
	GetCmdArg(1, strTarget, sizeof(strTarget));
	
	new String:targetName[MAX_TARGET_LENGTH];
	decl targetList[MAXPLAYERS + 1];
	decl targetCount;
	new bool:tn_is_ml;
	if ((targetCount = ProcessTargetString(
				strTarget, 
				client, 
				targetList, 
				MAXPLAYERS, 
				COMMAND_FILTER_CONNECTED + COMMAND_FILTER_NO_BOTS, 
				targetName, 
				sizeof(targetName), 
				tn_is_ml)) <= 0) {
		ReplyToTargetError(client, targetCount);
	} else {
		decl String:param2[MAX_TARGET_LENGTH];
		GetCmdArg(2, param2, sizeof(param2));
		new Float:damageFactor;
		damageFactor = StringToFloat(param2);
		for (new i = 0; i < targetCount; i++) {
			GetClientName(targetList[i], strTarget, sizeof(strTarget));
			switch (commandType) {
				case 1: {
					// COMMAND_TAKEDAMAGE
					g_PlayerTakeDamageMultiplier[targetList[i]] = damageFactor;
					ReplyToCommand(client, "%t", "CommandReplyTakeDamageSet", strTarget, damageFactor);
				}
				default: {
					// COMMAND_MAKEDAMAGE
					g_PlayerMakeDamageMultiplier[targetList[i]] = damageFactor;
					ReplyToCommand(client, "%t", "CommandReplyMakeDamageSet", strTarget, damageFactor);
				}
			}
		}
	}
	return Plugin_Handled;
}

//
// Private functions
//

/** 
 * Sets the TakeDamage and MakeDamage Factors to a given SteamID.
 *
 * @param steamID				Steam ID to seach for
 * @param takeDamage			will be set (default: 1.0) 
 * @param makeDamage			will be set (default: 1.0) 
 * @return
 */
GetFactorsToSteamID(const String:steamID[], Float:damageFactors[]) {
	new String:thisSteamID[STEAMID_LENGTH];
	new max = GetArraySize(g_ConfigPlayerSteamID);
	damageFactors[0] = 1.0;
	damageFactors[1] = 1.0;
	for (new i = 0; i < max; i++) {
		GetArrayString(g_ConfigPlayerSteamID, i, thisSteamID, sizeof(thisSteamID));
		if ((strcmp(thisSteamID, steamID, false) == 0)) {
			damageFactors[0] = Float:GetArrayCell(g_ConfigPlayerTakeDamage, i);
			damageFactors[1] = Float:GetArrayCell(g_ConfigPlayerMakeDamage, i);
			break;
		}
	}
}

/** 
 * Clean up on exit and close all handles
 *
 * @noreturn
 */
void ResetConfigArray() {
	ClearArray(g_ConfigPlayerSteamID);
	ClearArray(g_ConfigPlayerTakeDamage);
	ClearArray(g_ConfigPlayerMakeDamage);
	ResetPlayer(0);
}

/** 
 * Resets the damage multipiers for a single or all players
 *
 * @param client 	client id (0 = reset all players)
 * @noreturn
 */
void ResetPlayer(const client) {
	if (client == 0) {
		decl i;
		for (i = 0; i < sizeof(g_PlayerMakeDamageMultiplier); i++) {
			g_PlayerMakeDamageMultiplier[i] = 1.0;
			g_PlayerTakeDamageMultiplier[i] = 1.0;
		}
	} else if (client >= 0 && client < sizeof(g_PlayerMakeDamageMultiplier)) {
		g_PlayerMakeDamageMultiplier[client] = 1.0;
		g_PlayerTakeDamageMultiplier[client] = 1.0;
	}
}