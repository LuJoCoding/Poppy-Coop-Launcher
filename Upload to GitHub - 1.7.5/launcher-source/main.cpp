// PoppyCoop Launcher 3 - window and UI (plain GDI, immediate-mode: every paint rebuilds the click areas).
#include "core.h"
#include "crashreport.h"
#include "friends.h"
#include "friends_net.h"
#include "logs.h"
#include "zipwrite.h"
#include "splitscreen.h"
#include <windowsx.h>
#include <shobjidl.h>
#include <functional>
#include <thread>
#include <atomic>
#include <cmath>

// ------------------------------------------------------------------ messages from worker threads
enum { WM_APP_PROGRESS = WM_APP + 1, WM_APP_INSTALLED, WM_APP_PROBE, WM_APP_UPDATE, WM_APP_SELFUPD, WM_APP_MINSIZE, WM_APP_CRASHSENT, WM_APP_FRIENDS };
static bool g_updating = false;
static bool g_autoupd = true;      // Launcher settings: "Automatic updates" (ini Launcher AutoUpdate)
static int g_crashrep = -1;        // Launcher settings: "Send crash reports" (ini CrashReports): -1 not asked yet, 0 no, 1 yes
static ULONGLONG g_crash_check_at = 0;   // a game ended: look for a new crash report at this tick
static std::wstring g_friend_edit;       // friends page: name being typed
static void friends_refresh();
// friends server (friends_net.h): last list, whether it answers, background call running
static FriendsResult g_fnet;
static int g_fnet_state = 0;             // 0 not asked yet, 1 server answers, 2 not reachable / not set up
static bool g_fnet_busy = false;
static ULONGLONG g_fnet_hello_at = 0;    // last hello (status heartbeat, every 60 s once friends are used)
static void friends_net_sync(bool hello);
static int g_friends_on = -1;             // ini FriendsOn (set when the friends page is opened the first time)
static bool friends_used() {
    if (g_friends_on < 0) g_friends_on = ini_get(L"Launcher", L"FriendsOn", L"0") == L"1" ? 1 : 0;
    return g_friends_on == 1;
}
static std::wstring g_latest;      // newest release on GitHub (empty: unknown / offline)
// ------------------------------------------------------------------ language (English / Deutsch)
static int g_lang = 0;                    // 0 English, 1 Deutsch (ini [Launcher] Lang)
static const std::unordered_map<std::wstring, std::wstring>& de_table() {
    static const std::unordered_map<std::wstring, std::wstring> m = {
        { L" (update ready)", L" (Update bereit)" },
        { L" - testing the connection...", L" - Verbindung wird getestet..." },
        { L" - your figure's colour in other players' games", L" - die Farbe deiner Figur bei den anderen" },
        { L" available - download", L" verfügbar - herunterladen" },
        { L" in your ", L" in deinem " },
        { L" installed", L" installiert" },
        { L" is ready to be set up", L" ist bereit zur Einrichtung" },
        { L" isn't in that folder", L" ist nicht in diesem Ordner" },
        { L" settings", L" - Einstellungen" },
        { L" too.", L" auch." },
        { L" wasn't found automatically", L" wurde nicht automatisch gefunden" },
        { L". Pick the chapter and press PLAY!", L". Wähle das Kapitel und drücke SPIELEN!" },
        { L"A relay address (wss://...) or a friend's IP, e.g. 203.0.113.5 or 203.0.113.5:27777", L"Eine Relay-Adresse (wss://...) oder die IP eines Freundes, z. B. 203.0.113.5 oder 203.0.113.5:27777" },
        { L"ACCENT COLOUR", L"AKZENTFARBE" },
        { L"ADD A SERVER", L"SERVER HINZUFÜGEN" },
        { L"ADD A SERVER (remove one first - 3 at most)", L"SERVER HINZUFÜGEN (erst einen entfernen - höchstens 3)" },
        { L"Add", L"Hinzufügen" },
        { L"Added ", L"Hinzugefügt: " },
        { L"Animations", L"Animationen" },
        { L"Ask your friend for their code, or just open the invite link they sent you.", L"Frag deinen Freund nach seinem Code oder öffne einfach den Einladungslink, den er dir geschickt hat." },
        { L"Browse", L"Durchsuchen" },
        { L"CHAPTER ", L"KAPITEL " },
        { L"CO-OP", L"KOOP" },
        { L"CO-OP MOD", L"KOOP-MOD" },
        { L"Careful: the game uses ", L"Achtung: das Spiel benutzt " },
        { L"Change folder", L"Ordner ändern" },
        { L"Chapter ", L"Kapitel " },
        { L"Chapters 3 to 5 come in a later update. You can set up another chapter any time from the list on the left.", L"Kapitel 3 bis 5 kommen in einem späteren Update. Du kannst jederzeit links ein weiteres Kapitel einrichten." },
        { L"Choose folder...", L"Ordner wählen..." },
        { L"Click a key, then press the new one", L"Taste klicken, neue drücken" },
        { L"Click to confirm", L"Zum Bestätigen klicken" },
        { L"Close Poppy Playtime first so the mod can be installed.", L"Schließe zuerst Poppy Playtime, damit die Mod installiert werden kann." },
        { L"Close the game first.", L"Schließe zuerst das Spiel." },
        { L"Co-op for this chapter is still being built. It unlocks in a future update of the launcher.", L"Koop für dieses Kapitel ist noch in Arbeit. Es kommt mit einem späteren Launcher-Update." },
        { L"Co-op mod not installed yet - it installs when you press Play", L"Koop-Mod noch nicht installiert - sie wird beim Klick auf Spielen installiert" },
        { L"Co-op mod removed - your game is back to normal.", L"Koop-Mod entfernt - dein Spiel ist wieder normal." },
        { L"Co-op mod v", L"Koop-Mod v" },
        { L"Coming later", L"Kommt später" },
        { L"Copied to clipboard!  Room code ", L"In die Zwischenablage kopiert!  Raum-Code " },
        { L"Copy code", L"Code kopieren" },
        { L"Copy invite", L"Einladung kopieren" },
        { L"Couldn't remove everything - close the game or run the launcher as administrator.", L"Konnte nicht alles entfernen - schließe das Spiel oder starte den Launcher als Administrator." },
        { L"Couldn't save the mod settings - close the game or run the launcher as administrator.", L"Konnte die Mod-Einstellungen nicht speichern - schließe das Spiel oder starte den Launcher als Administrator." },
        { L"Couldn't save the mod settings - try running the launcher as administrator.", L"Konnte die Mod-Einstellungen nicht speichern - starte den Launcher als Administrator." },
        { L"Couldn't start the game.", L"Konnte das Spiel nicht starten." },
        { L"Done", L"Fertig" },
        { L"Everyone you play with has to pick the same server.", L"Alle, mit denen du spielst, müssen denselben Server wählen." },
        { L"F6 takes you to a friend - even to their later checkpoint.", L"F6 bringt dich zu einem Freund - auch zu seinem späteren Checkpoint." },
        { L"F8 / F9 are kept free for other mods - pick another key.", L"F8 / F9 bleiben für andere Mods frei - wähle eine andere Taste." },
        { L"FIGURE COLOUR", L"FIGURFARBE" },
        { L"FRIEND'S ROOM CODE", L"RAUM-CODE DEINES FREUNDES" },
        { L"Found Chapter ", L"Gefunden: Kapitel " },
        { L"Game found - ready to set up  \x203A", L"Spiel gefunden - bereit zur Einrichtung  \x203A" },
        { L"Have fun! F6 = go to a friend, T = ping a spot.", L"Viel Spaß! F6 = zu einem Freund, T = Stelle markieren." },
        { L"How the launcher looks. This doesn't change anything in the game.", L"Wie der Launcher aussieht. Ändert nichts im Spiel." },
        { L"If the game is somewhere else (another drive, a copied folder), choose the folder that contains ", L"Liegt das Spiel woanders (andere Festplatte, kopierter Ordner), wähle selbst den Ordner, der " },
        { L" yourself.", L" enthält." },
        { L"Install co-op mod", L"Koop-Mod installieren" },
        { L"Install failed - close the game, or run the launcher as administrator.", L"Installation fehlgeschlagen - schließe das Spiel oder starte den Launcher als Administrator." },
        { L"Invite copied - paste it to your friends!", L"Einladung kopiert - schick sie deinen Freunden!" },
        { L"Invite opened - room ", L"Einladung geöffnet - Raum " },
        { L"Is this the right folder? If not, pick another one with Browse.", L"Ist das der richtige Ordner? Wenn nicht, wähle mit Durchsuchen einen anderen." },
        { L"Jump straight in and play with anyone who's online right now. No code needed.", L"Direkt loslegen und mit allen spielen, die gerade online sind. Kein Code nötig." },
        { L"Keys reset to the defaults.", L"Tasten auf Standard zurückgesetzt." },
        { L"Launcher settings", L"Launcher-Einstellungen" },
        { L"Log selected + its end copied - paste it in Discord (Ctrl+V).", L"Log markiert + Ende kopiert - füge es in Discord ein (Strg+V)." },
        { L"Measuring...", L"Messe..." },
        { L"My figure colour", L"Meine Figurfarbe" },
        { L"Name & colour", L"Name & Farbe" },
        { L"Name & colour  \x203A", L"Name & Farbe  \x203A" },
        { L"New code", L"Neuer Code" },
        { L"No folder selected yet - click Browse", L"Noch kein Ordner gewählt - klicke auf Durchsuchen" },
        { L"No game log yet - start the game once.", L"Noch kein Spiel-Log - starte das Spiel einmal." },
        { L"No room code on the clipboard.", L"Kein Raum-Code in der Zwischenablage." },
        { L"Not installed", L"Nicht installiert" },
        { L"OK?", L"OK?" },
        { L"Only found the old Chapter 1 - co-op needs v1.3.", L"Nur das alte Kapitel 1 gefunden - Koop braucht v1.3." },
        { L"Open folder", L"Ordner öffnen" },
        { L"PLAYER NAME", L"SPIELERNAME" },
        { L"POPPY PLAYTIME", L"POPPY PLAYTIME" },
        { L"Paste", L"Einfügen" },
        { L"Pasted room code ", L"Raum-Code eingefügt: " },
        { L"Pick the chapter you want to play. The launcher only asks for that chapter's game folder - you don't need the other chapters.", L"Wähle das Kapitel, das du spielen willst. Der Launcher fragt nur nach dem Spielordner dieses Kapitels - die anderen brauchst du nicht." },
        { L"Play Poppy Playtime together", L"Poppy Playtime zusammen spielen" },
        { L"Playing as ", L"Du spielst als " },
        { L"Poppy Playtime found (version couldn't be checked)", L"Poppy Playtime gefunden (Version nicht prüfbar)" },
        { L"Public lobby", L"Öffentliche Lobby" },
        { L"Recent:", L"Zuletzt:" },
        { L"Played with: ", L"Gespielt mit: " },
        { L"Reinstall", L"Neu installieren" },
        { L"Reset keys", L"Tasten zurücksetzen" },
        { L"SET UP CHAPTER ", L"KAPITEL EINRICHTEN " },
        { L"SHARED WITH YOUR ROOM", L"MIT DEINEM RAUM GETEILT" },
        { L"Saved - takes effect next time you start the game.", L"Gespeichert - gilt beim nächsten Spielstart." },
        { L"Search again", L"Erneut suchen" },
        { L"Server & connection", L"Server & Verbindung" },
        { L"Set up  \x203A", L"Einrichten  \x203A" },
        { L"Settings", L"Einstellungen" },
        { L"Logs", L"Logs" },
        { L"Layout: ", L"Aufteilung: " },
        { L"Off", L"Aus" },
        { L"Left / right", L"Links / rechts" },
        { L"Top / bottom", L"Oben / unten" },
        { L"One per monitor", L"Ein Monitor pro Spiel" },
        { L"Split screen: PLAY starts more game windows.", L"Splitscreen: SPIELEN startet weitere Spielfenster." },
        { L"Next start: the game windows are placed ", L"Ab dem nächsten Start: Spielfenster " },
        { L"Game windows are not arranged.", L"Spielfenster werden nicht angeordnet." },
        { L"CRASH REPORTS", L"ABSTURZBERICHTE" },
        { L"Send crash reports to the developers?", L"Absturzberichte an die Entwickler senden?" },
        { L"When the game crashes, the launcher can send the error message, the end of the mod's log, the mod version and your Windows version to the PoppyCoop developers. User names in folder paths are removed. It helps us fix crashes. You can change this any time in the launcher settings.", L"Wenn das Spiel abstürzt, kann der Launcher die Fehlermeldung, das Ende des Mod-Logs, die Mod-Version und deine Windows-Version an die PoppyCoop-Entwickler schicken. Benutzernamen in Ordnerpfaden werden entfernt. Das hilft uns, Abstürze zu beheben. Du kannst das jederzeit in den Launcher-Einstellungen ändern." },
        { L"Yes, send them", L"Ja, senden" },
        { L"No", L"Nein" },
        { L"Co-op without the launcher", L"Koop auch ohne Launcher" },
        { L"Also when the game is started from Steam (e.g. Steam Deck game mode). Off: only via PLAY here.", L"Auch wenn das Spiel über Steam gestartet wird (z. B. Steam-Deck-Spielmodus). Aus: nur über SPIELEN hier." },
        { L"WHAT'S NEW", L"WAS IST NEU" },
        { L"All releases on GitHub", L"Alle Versionen auf GitHub" },
        { L"PoppyCoop_report.zip is in the launcher folder - send it to us.", L"PoppyCoop_report.zip liegt im Launcher-Ordner - schick sie uns." },
        { L"Logs & crashes", L"Logs & Abstürze" },
        { L"Running now", L"Läuft gerade" },
        { L"game crashed", L"Spiel abgestürzt" },
        { L"Crash report only - the session's log was overwritten", L"Nur Absturzbericht - das Log dieser Sitzung wurde überschrieben" },
        { L"under 1 min", L"unter 1 Min" },
        { L" errors", L" Fehler" },
        { L" logs", L" Logs" },
        { L"Refresh", L"Aktualisieren" },
        { L" invites you - open Friends to join.", L" lädt dich ein - öffne Freunde zum Beitreten." },
        { L"Invite sent - they see it in their launcher.", L"Einladung gesendet - dein Freund sieht sie im Launcher." },
        { L"Invites need the new friends server - coming soon.", L"Einladungen brauchen den neuen Freunde-Server - kommt bald." },
        { L"You can only invite friends.", L"Du kannst nur Freunde einladen." },
        { L" invites you", L" lädt dich ein" },
        { L"Join now", L"Jetzt beitreten" },
        { L"On", L"An" },
        { L"FRIEND'S SETTINGS", L"EINSTELLUNGEN DES FREUNDES" },
        { L" plays with other settings", L" spielt mit anderen Einstellungen" },
        { L"Different settings make different games (items, doors, enemies). Take theirs? The game restarts and you join the same room again.", L"Unterschiedliche Einstellungen ergeben unterschiedliche Spiele (Items, Türen, Gegner). Die Einstellungen des Freundes übernehmen? Das Spiel startet neu und du kommst wieder in denselben Raum." },
        { L"Take them & restart", L"Übernehmen & neu starten" },
        { L"Keep mine", L"Meine behalten" },
        { L"friend: ", L"Freund: " },
        { L"you: ", L"du: " },
        { L"Taking the settings - the game restarts...", L"Einstellungen übernommen - das Spiel startet neu..." },
        { L"The game didn't close - close it, then press PLAY.", L"Das Spiel wurde nicht geschlossen - schließe es und drücke SPIELEN." },
        { L"Dismiss", L"Ablehnen" },
        { L"Invite", L"Einladen" },
        { L"Pick Create Game first - then invite.", L"Wähle zuerst Spiel erstellen - dann einladen." },
        { L"Joining ", L"Trete bei: " },
        { L" - close the game, then press PLAY.", L" - schließe das Spiel, dann SPIELEN drücken." },
        { L" isn't set up here yet - room code filled in.", L" ist hier noch nicht eingerichtet - Raumcode eingetragen." },
        { L"  -  installed", L"  -  installiert" },
        { L"Your last game sessions. Crashed ones are red - send us the report zip or copy the log into Discord.", L"Deine letzten Spielsitzungen. Abgestürzte sind rot - schick uns die Bericht-Zip oder kopier das Log in Discord." },
        { L"No logs yet - they show up here after you played this chapter once.", L"Noch keine Logs - sie erscheinen hier, sobald du dieses Kapitel einmal gespielt hast." },
        { L"Crashed", L"Abgestürzt" },
        { L"  -  arrow keys / click", L"  -  Pfeiltasten / Klick" },
        { L"LIVE LOG", L"LIVE-LOG" },
        { L"CRASH", L"ABSTURZ" },
        { L"GAME LOG", L"SPIEL-LOG" },
        { L"Copy for Discord", L"Für Discord kopieren" },
        { L"Copied - paste it in Discord (Ctrl+V).", L"Kopiert - in Discord einfügen (Strg+V)." },
        { L"Report zip", L"Bericht-Zip" },
        { L"Couldn't make the zip - use Copy for Discord or Open folder.", L"Zip ging nicht - nimm Für Discord kopieren oder Ordner öffnen." },
        { L"PoppyCoop_report.zip is on your desktop - send it to us.", L"PoppyCoop_report.zip liegt auf deinem Desktop - schick sie uns." },
        { L"Open log", L"Log öffnen" },
        { L"This crash has no log any more.", L"Zu diesem Absturz gibt es kein Log mehr." },
        { L"Share the code or the invite. Friends pick Join Game and enter it.", L"Teile den Code oder die Einladung. Freunde wählen Beitreten und geben ihn ein." },
        { L"Show game log (after a crash)", L"Spiel-Log zeigen (nach Absturz)" },
        { L"PoppyCoop_report.zip is on your desktop (log end also copied) - send it to us.", L"PoppyCoop_report.zip liegt auf dem Desktop (Log-Ende auch kopiert) - schick es uns." },
        { L"Smooth fades and movements. Turn off on very slow PCs.", L"Weiche Übergänge und Bewegungen. Auf sehr langsamen PCs ausschalten." },
        { L"Starting Poppy Playtime - Steam may take a few seconds", L"Poppy Playtime startet - Steam braucht evtl. ein paar Sekunden" },
        { L"Starting Poppy Playtime...", L"Poppy Playtime startet..." },
        { L"Still not found - choose the folder yourself.", L"Immer noch nicht gefunden - wähle den Ordner selbst." },
        { L"Swapped with \"", L"Getauscht mit \"" },
        { L"Test again", L"Erneut testen" },
        { L"Testing...", L"Teste..." },
        { L"That doesn't look like a server address.", L"Das sieht nicht wie eine Server-Adresse aus." },
        { L"That key can't be used - pick another one.", L"Diese Taste geht nicht - wähle eine andere." },
        { L"That server is already in the list.", L"Dieser Server ist schon in der Liste." },
        { L"The game didn't open yet - check Steam.", L"Das Spiel ist noch nicht offen - prüfe Steam." },
        { L"The game is already running - close it to switch rooms.", L"Das Spiel läuft schon - schließe es, um den Raum zu wechseln." },
        { L"The game is running - changes apply next time you start it.", L"Das Spiel läuft - Änderungen gelten beim nächsten Start." },
        { L"The launcher looked in all your Steam libraries and in Steam's download folder - a version downloaded with the Steam console (downpatch) always ends up there:", L"Der Launcher hat in allen Steam-Bibliotheken und im Steam-Download-Ordner gesucht - eine mit der Steam-Konsole (Downpatch) geladene Version landet immer hier:" },
        { L"This is the old Chapter 1 - update it to v1.3 in Steam first", L"Das ist das alte Kapitel 1 - aktualisiere es zuerst in Steam auf v1.3" },
        { L"Type a name first.", L"Gib zuerst einen Namen ein." },
        { L"Type your friend's room code first.", L"Gib zuerst den Raum-Code deines Freundes ein." },
        { L"UE4SS.log is selected - send it to us (Discord) together with what happened.", L"UE4SS.log ist markiert - schick sie uns (Discord) mit einer Beschreibung, was passiert ist." },
        { L"Uninstall", L"Deinstallieren" },
        { L"Update available: v", L"Update verfügbar: v" },
        { L"Update v", L"Update v" },
        { L" available - install", L" verfügbar - installieren" },
        { L"Updating...", L"Wird aktualisiert..." },
        { L"Downloading the update...", L"Update wird heruntergeladen..." },
        { L"Automatic update failed - opening the download page.", L"Automatisches Update fehlgeschlagen - Download-Seite wird geöffnet." },
        { L"Use the same settings as your friends.", L"Benutzt dieselben Einstellungen wie deine Freunde." },
        { L"What should other players call you?", L"Wie sollen dich die anderen nennen?" },
        { L"What's new", L"Was ist neu" },
        { L"YOUR ROOM CODE", L"DEIN RAUM-CODE" },
        { L"You are the server", L"Du bist der Server" },
        { L"Your name floats above your figure in everyone else's game. Letters, numbers, _ and - only.", L"Dein Name schwebt bei allen anderen über deiner Figur. Nur Buchstaben, Zahlen, _ und -." },
        { L"\"My figure colour\" follows the colour you play with (Name & colour).", L"\"Meine Figurfarbe\" folgt der Farbe, mit der du spielst (Name & Farbe)." },
        { L"\x2039  Back", L"\x2039  Zurück" },
        { L"friends connect to you", L"Freunde verbinden sich mit dir" },
        { L"In game", L"Im Spiel" },
        { L"Not set up yet", L"Noch nicht eingerichtet" },
        { L"Installs when you play", L"Wird beim Spielen installiert" },
        { L"Update ready", L"Update bereit" },
        { L"Your room ", L"Dein Raum " },
        { L"Room ", L"Raum " },
        { L"Fan-made co-op mod. Not affiliated with Mob Entertainment.", L"Fan-Mod. Nicht verbunden mit Mob Entertainment." },
        { L"KEYS", L"TASTEN" },
        { L"THEME", L"DESIGN" },
        { L"WELCOME", L"WILLKOMMEN" },
        { L"LAUNCHER", L"LAUNCHER" },
        { L"SERVERS", L"SERVER" },
        { L"CHAPTERS", L"KAPITEL" },
        { L"Quick Play", L"Schnellspiel" },
        { L"Create Game", L"Spiel erstellen" },
        { L"Join Game", L"Beitreten" },
        { L"PLAY", L"SPIELEN" },
        { L"READY", L"BEREIT" },
        { L"BETA", L"BETA" },
        { L"SOON", L"BALD" },
        { L"LANGUAGE", L"SPRACHE" },
        { L"Speedrun mode", L"Speedrun-Modus" },
        { L"Automatic updates", L"Automatische Updates" },
        { L" new", L" neu" },
        { L" online", L" online" },
        { L"One moment...", L"Einen Moment..." },
        { L"No player with that friend code.", L"Kein Spieler mit diesem Freundes-Code." },
        { L"You are already friends.", L"Ihr seid schon befreundet." },
        { L"Too many requests - try again later.", L"Zu viele Anfragen - versuch es später nochmal." },
        { L"Friends server: your account key doesn't match.", L"Freunde-Server: dein Konto-Schlüssel passt nicht." },
        { L"Friends server error: ", L"Fehler beim Freunde-Server: " },
        { L"Your friend code is now ", L"Dein Freundes-Code ist jetzt " },
        { L"You are friends now!", L"Ihr seid jetzt Freunde!" },
        { L"Friend request sent.", L"Freundschaftsanfrage gesendet." },
        { L"Request declined.", L"Anfrage abgelehnt." },
        { L"Removed.", L"Entfernt." },
        { L"Send a friend request with their friend code. Friends see each other online and can join each other.", L"Schick eine Freundschaftsanfrage mit dem Freundes-Code. Freunde sehen sich online und können sich beitreten." },
        { L"Send request", L"Anfrage senden" },
        { L"wants to be your friend", L"möchte dein Freund sein" },
        { L"Accept", L"Annehmen" },
        { L"Decline", L"Ablehnen" },
        { L"No friends yet - send a request with a friend code, or to someone you played with below.", L"Noch keine Freunde - schick eine Anfrage mit einem Freundes-Code oder an jemanden unten, mit dem du gespielt hast." },
        { L"Offline", L"Offline" },
        { L"Online", L"Online" },
        { L"Playing Chapter ", L"Spielt Kapitel " },
        { L" - room ", L" - Raum " },
        { L"Join", L"Beitreten" },
        { L"Waiting for ", L"Warte auf " },
        { L" to accept", L" (noch nicht angenommen)" },
        { L"Cancel", L"Zurückziehen" },
        { L"Nobody new yet - players show up here after you played together.", L"Noch niemand Neues - Spieler erscheinen hier, nachdem ihr zusammen gespielt habt." },
        { L"Friends server not reachable - showing your local list.", L"Freunde-Server nicht erreichbar - lokale Liste wird angezeigt." },
        { L"Friends", L"Freunde" },
        { L"FRIENDS", L"FREUNDE" },
        { L"Your friends", L"Deine Freunde" },
        { L"Add the people you play with. Their last room is remembered - join it with one click.", L"Füge die Leute hinzu, mit denen du spielst. Ihr letzter Raum wird gemerkt - mit einem Klick beitreten." },
        { L"Friend code, e.g. Max#12345", L"Freundes-Code, z.B. Max#12345" },
        { L"YOUR FRIEND CODE", L"DEIN FREUNDES-CODE" },
        { L"Copy", L"Kopieren" },
        { L"Copied: ", L"Kopiert: " },
        { L"Add friends with their friend code. Their last room is remembered - join it with one click.", L"Füge Freunde mit ihrem Freundes-Code hinzu. Ihr letzter Raum wird gemerkt - mit einem Klick beitreten." },
        { L"Enter the whole friend code with the number, e.g. Max#12345.", L"Gib den ganzen Freundes-Code mit Nummer ein, z.B. Max#12345." },
        { L"That's your own friend code.", L"Das ist dein eigener Freundes-Code." },
        { L"Type your friend's code first (Name#12345).", L"Gib zuerst den Code deines Freundes ein (Name#12345)." },
        { L"No friends yet - add a friend code above, or pick someone you played with below.", L"Noch keine Freunde - oben einen Freundes-Code eintragen oder unten jemanden auswählen, mit dem du gespielt hast." },
        { L"Players with an older version show without a number. Online status and invites come later.", L"Spieler mit älterer Version erscheinen ohne Nummer. Online-Status und Einladungen kommen später." },
        { L"Add", L"Hinzufügen" },
        { L"Type your friend's player name first.", L"Gib zuerst den Spielernamen deines Freundes ein." },
        { L" is now your friend.", L" ist jetzt dein Freund." },
        { L" is already your friend.", L" ist schon dein Freund." },
        { L"The friend list is full.", L"Die Freundesliste ist voll." },
        { L"No friends yet - add a name above, or pick someone you played with below.", L"Noch keine Freunde - oben einen Namen eintragen oder unten jemanden auswählen, mit dem du gespielt hast." },
        { L"Not played together yet", L"Noch nicht zusammen gespielt" },
        { L"Last room: ", L"Letzter Raum: " },
        { L"Join their room", L"Raum beitreten" },
        { L"Remove", L"Entfernen" },
        { L" removed.", L" entfernt." },
        { L" more (make the window bigger)", L" weitere (Fenster größer ziehen)" },
        { L"RECENTLY PLAYED WITH", L"ZULETZT GESPIELT MIT" },
        { L"Nobody new yet - names show up here after you played together.", L"Noch niemand Neues - Namen erscheinen hier, nachdem ihr zusammen gespielt habt." },
        { L"Online status and invites are coming later (they need a server).", L"Online-Status und Einladungen kommen später (dafür braucht es einen Server)." },
        { L"Room code of ", L"Raum-Code von " },
        { L" - press PLAY to join.", L" - drücke SPIELEN zum Beitreten." },
        { L"Send crash reports", L"Absturzberichte senden" },
        { L"After a crash, send the error and the mod log to the developers (no user names).", L"Nach einem Absturz Fehler und Mod-Log an die Entwickler senden (ohne Benutzernamen)." },
        { L"Crash reports", L"Absturzberichte" },
        { L"When the game crashes, may the launcher send a crash report to the PoppyCoop developers?\n\nIt contains the error message, the end of the mod's log, the mod version and your Windows version - user names in folder paths are removed. It helps us fix crashes.\n\nYou can change this any time in the launcher settings.",
          L"Darf der Launcher nach einem Absturz einen Bericht an die PoppyCoop-Entwickler schicken?\n\nEr enthält die Fehlermeldung, das Ende des Mod-Logs, die Mod-Version und deine Windows-Version - Benutzernamen in Ordnerpfaden werden entfernt. Das hilft uns, Abstürze zu beheben.\n\nDu kannst das jederzeit in den Launcher-Einstellungen ändern." },
        { L"The game crashed - a crash report was sent to the developers. Thanks!", L"Das Spiel ist abgestürzt - ein Absturzbericht wurde an die Entwickler geschickt. Danke!" },
        { L"The game crashed - sending the crash report failed. \"Report a problem\" makes a zip for us.", L"Das Spiel ist abgestürzt - der Bericht konnte nicht gesendet werden. \"Problem melden\" macht ein Zip für uns." },
        { L"Install a new version by itself when the launcher starts.", L"Neue Version beim Start des Launchers selbst installieren." },
        { L"Updating to v", L"Aktualisiere auf v" },
        { L"Updated to v", L"Aktualisiert auf v" },
        { L"Speedrun mode on: only doors, inventory and hands are shared.", L"Speedrun-Modus an: nur Türen, Inventar und Hände werden geteilt." },
        { L"Speedrun mode off: default settings.", L"Speedrun-Modus aus: Standard-Einstellungen." },
        { L"Only what a run needs (doors, inventory, hands), max fps", L"Nur was ein Run braucht (Türen, Inventar, Hände), max. fps" },
        { L"Doors, switches & puzzles", L"Türen, Schalter & Rätsel" },
        { L"Doors, power, levers, puzzle parts", L"Türen, Strom, Hebel, Rätselteile" },
        { L"Picked-up items", L"Aufgehobene Gegenstände" },
        { L"Gone for everyone once picked up", L"Für alle weg, sobald aufgehoben" },
        { L"Shared inventory", L"Gemeinsames Inventar" },
        { L"One team inventory for keys & items", L"Ein Team-Inventar für Schlüssel & Gegenstände" },
        { L"Shared GrabPack hands", L"Gemeinsame GrabPack-Hände" },
        { L"A new hand goes to everyone", L"Eine neue Hand bekommen alle" },
        { L"Pullable objects", L"Ziehbare Objekte" },
        { L"Boxes, barrels, chairs move for all", L"Kisten, Fässer, Stühle bewegen sich für alle" },
        { L"Keep friends' areas loaded", L"Bereiche der Freunde geladen halten" },
        { L"Off = safer: their rooms' enemies can't reach you", L"Aus = sicherer: Gegner aus ihren Räumen erreichen dich nicht" },
        { L"Minigames", L"Minispiele" },
        { L"Musical Memory, Whack-a-Wuggy", L"Musical Memory, Whack-a-Wuggy" },
        { L"Follow out of chases", L"Aus Verfolgungen mitnehmen" },
        { L"Friend escaped a chase you're in: go to them", L"Freund entkommt einer Verfolgung, in der du steckst: zu ihm" },
        { L"Respawn at a friend", L"Beim Freund wiederbeleben" },
        { L"After dying you are teleported to a friend", L"Nach dem Tod wirst du zu einem Freund teleportiert" },
        { L"Solid friends", L"Freunde sind fest" },
        { L"You can't walk through friends and can stand on their head", L"Man läuft nicht durch Freunde und kann auf ihrem Kopf stehen" },
        { L"Limit to 60 fps", L"Auf 60 fps begrenzen" },
        { L"Performance mode", L"Leistungsmodus" },
        { L"Harder enemies", L"Stärkere Gegner" },
        { L"Shared monsters (experimental)", L"Gemeinsame Monster (experimentell)" },
        { L"Huggy, Mommy & co. chase the same player for all", L"Huggy, Mommy & Co. jagen bei allen denselben Spieler" },
        { L"Enemies get faster with every extra player", L"Gegner werden mit jedem weiteren Spieler schneller" },
        { L"Lower shadows and effects for more fps on weak PCs (switching it off restores them)", L"Weniger Schatten und Effekte für mehr fps auf schwachen PCs (Ausschalten stellt sie wieder her)" },
        { L"Smoother on weaker PCs, less heat", L"Ruhiger auf schwächeren PCs, weniger Hitze" },
        { L"On-screen messages", L"Meldungen im Spiel" },
        { L"Joined / died / teleport messages", L"Beigetreten / gestorben / Teleport-Meldungen" },
        { L"Teleport to a friend", L"Zu einem Freund teleportieren" },
        { L"Show / hide buddy figure", L"Begleitfigur zeigen / verstecken" },
        { L"Record your movement", L"Bewegung aufnehmen" },
        { L"Replay recorded movement", L"Aufnahme abspielen" },
        { L"Ping a spot for everyone", L"Stelle für alle markieren" },
        { L"Show fps / ping / players", L"fps / Ping / Spieler zeigen" },
        { L"Chat menu", L"Chat-Menü" },
        { L"TEST", L"TEST" },
        { L"Experimental chapters", L"Experimentelle Kapitel" },
        { L"Try Chapters 3-5: you see each other, but doors, puzzles and items aren't shared.", L"Kapitel 3-5 testen: ihr seht euch, Türen/Rätsel/Items noch nicht geteilt." },
        { L"Several games at once", L"Mehrere Spiele gleichzeitig" },
        { L"For Nucleus Co-op / split screen: PLAY can start more game windows.", L"Für Nucleus Co-op / Splitscreen: SPIELEN kann weitere Spielfenster starten." },
        { L"Experimental: you see each other, can teleport, ping and chat. Doors, puzzles and items are NOT shared yet, and the game may crash.", L"Experimentell: ihr seht euch, könnt teleportieren, markieren und chatten. Türen, Rätsel und Gegenstände werden noch NICHT geteilt, und das Spiel kann abstürzen." },
        { L"Experimental", L"Experimentell" },
        { L"Full co-op for this chapter is still being built. You can already try it as experimental: you see each other, but doors, puzzles and items aren't shared.", L"Volles Co-op für dieses Kapitel ist noch in Arbeit. Du kannst es schon experimentell testen: ihr seht euch, aber Türen, Rätsel und Gegenstände werden nicht geteilt." },
        { L"Turn on experimental chapters", L"Experimentelle Kapitel einschalten" },
        { L"Experimental chapters are on - pick Chapter 3, 4 or 5 on the left.", L"Experimentelle Kapitel sind an - wähle links Kapitel 3, 4 oder 5." },
        { L"Try world sync", L"Welt-Sync testen" },
        { L"Doors, items, puzzles - may not work or crash", L"Türen, Gegenstände, Rätsel - kann fehlschlagen oder abstürzen" },
        { L"F10 opens the game console - pick another key.", L"F10 öffnet die Spielkonsole - nimm eine andere Taste." },
        { L"PLAY ANOTHER", L"NOCH EINS" },
        { L"Started game window ", L"Spielfenster gestartet: " },
        { L"the game's .exe", L"die .exe des Spiels" },
        { L"Off = safer: their enemies can't reach you", L"Aus = sicherer: ihre Gegner erreichen dich nicht" },
        { L"How the launcher looks, plus a few extras.", L"Wie der Launcher aussieht, plus ein paar Extras." },
        { L"Chapters 3 to 5 can be tried as experimental (Launcher settings). You can set up another chapter any time from the list on the left.", L"Kapitel 3 bis 5 kannst du experimentell testen (Launcher-Einstellungen). Ein anderes Kapitel kannst du jederzeit links in der Liste einrichten." },
        { L"Explore the abandoned toy factory together. Doors, power, puzzles, items, pullable objects and loaded areas are shared with everyone in your room.", L"Erkundet zusammen die verlassene Spielzeugfabrik. Türen, Strom, Rätsel, Gegenstände, ziehbare Objekte und geladene Bereiche werden mit allen im Raum geteilt." },
        { L"Explore the Game Station together. Doors, keys and items, power, checkpoints, pullable objects and loaded areas are shared - and Musical Memory and Whack-a-Wuggy are played together.", L"Erkundet zusammen die Game Station. Türen, Schlüssel und Gegenstände, Strom, Hebel und ziehbare Objekte werden geteilt - Musical Memory und Whack-a-Wuggy spielt ihr zusammen." },
        { L"Beta: you see each other, and levers, valves, hand scanners, doors, picked-up items and story progress are shared. Some puzzles and chases aren't yet.", L"Beta: ihr seht euch, und Hebel, Ventile, Handscanner, Türen, aufgehobene Gegenstände und Story-Fortschritt werden geteilt. Manche Rätsel und Verfolgungen noch nicht." }
    };
    return m;
}
static std::wstring tr(const std::wstring& en) {
    if (g_lang != 1) return en;
    auto& m = de_table();
    auto it = m.find(en);
    return it == m.end() ? en : it->second;
}

// "What's new" page: this version's items first, then earlier versions in short (old = shown dimmed)
struct NewsItem { bool old; const wchar_t* title; const wchar_t* text; const wchar_t* title_de; const wchar_t* text_de; };
// (the "What's new" page shows release/notes of every version: see draw_news)
enum { TIMER_POLL = 1, TIMER_CARET = 2, TIMER_ANIM = 3, TIMER_PROBE = 4, TIMER_MINSIZE = 5, TIMER_SPLIT = 6 };

// ------------------------------------------------------------------ state
enum class Page { Welcome, Chapter, Settings, Profile, App, Servers, Friends, Logs, News };

static HWND g_wnd;
static Profile g_prof;
static int g_sel = 0;                        // selected chapter index
static Page g_page = Page::Chapter;
static double g_s = 1.0;                     // drawing scale = DPI scale * window zoom
static double g_dpi = 1.0, g_zoom = 1.0;
static std::wstring g_toast;
static ULONGLONG g_toast_until = 0;
static std::atomic<bool> g_installing{ false };
static int g_install_pct = 0;
static int g_install_ch = -1;
static bool g_launch_after_install = false;
static int g_starting_ch = -1;               // waiting for the game process to appear
static ULONGLONG g_starting_t0 = 0;
static bool g_running[8] = {};
static Page g_news_back = Page::Chapter;      // page to go back to from the news page
static std::vector<LogEntry> g_logs;         // Logs page: sessions + crashes of the selected chapter (read when opened)
static int g_log_sel = 0;
static int g_log_scroll = 0;                 // log preview: lines scrolled up from the end
static int g_log_page = 1;                   // log preview: lines that fit
static RECT g_log_view = {};                 // log preview area (pixels, page coordinates) - the wheel scrolls the log there
// scroll bar of the log preview (pixels, page coordinates) - can be dragged
static RECT g_log_track = {};                // whole bar (wider than drawn, easier to hit)
static int g_log_thumb_top = 0, g_log_thumb_h = 0, g_log_total = 0;
static bool g_log_drag = false;
static int g_log_grab = 0;                   // where the thumb was grabbed (pixels from its top)
static void log_drag_to(int y) {
    int th = g_log_track.bottom - g_log_track.top, room = g_log_page, range = g_log_total - room;
    if (range <= 0 || th <= g_log_thumb_h) return;
    int pos = y - g_log_track.top - g_log_grab;
    int firstl = (int)((long long)pos * range / (th - g_log_thumb_h) + 0.5);
    firstl = std::max(0, std::min(range, firstl));
    g_log_scroll = range - firstl;
}
static void log_select(int i) { g_log_sel = i; g_log_scroll = 0; }
static void log_scroll(int d) {
    int mx = g_logs.empty() ? 0 : std::max(0, (int)g_logs[std::min(g_log_sel, (int)g_logs.size() - 1)].tail.size() - g_log_page);
    g_log_scroll = std::max(0, std::min(mx, g_log_scroll + d));
}
static int g_capture = -1;                   // key row waiting for a key press (settings page)
static bool g_confirm_uninstall = false;
static std::wstring g_edit_name;             // profile page buffer
static int g_view = 0;
// servers (Servers page): built-in relay + "host on this PC" + the player's own entries
static std::vector<Server> g_servers;
static int g_srv = 0;
static std::vector<std::pair<std::wstring, Probe>> g_probes;   // by server key
static std::atomic<bool> g_probing{ false };
static std::wstring g_new_name, g_new_addr, g_lan;
static int g_confirm_remove = -1;                       // what the chapter page shows (setup / not found / play...), part of the fade signature

static int S(double v) { return (int)(v * g_s + 0.5); }

// Own title bar: Proton (Steam on Linux / Steam Deck) removes the desktop's window frame from every window and
// draws an old Windows 95 style caption instead. There the launcher draws its own dark bar (move, double-click
// to maximize, resize at the edges, minimize / maximize / close). Windows and plain Wine keep the normal frame.
// launcher.ini [Launcher] OwnTitleBar=1 / 0 forces it on / off.
static bool g_own_bar = false;
static const int TITLE_BAR_H = 32, TITLE_BTN_W = 46, RESIZE_EDGE = 6;
static RECT g_normal_rect = {};      // window rect before maximizing (Proton restores to the minimum size otherwise)
static int bar_h() { return g_own_bar ? (int)(TITLE_BAR_H * g_dpi + 0.5) : 0; }
static void adjust_window_rect(RECT& r, DWORD style) {
    if (g_own_bar) r.bottom += bar_h();
    else AdjustWindowRect(&r, style, FALSE);
}

// installed mod version + "setup done" per chapter, cached (paint runs at 60 fps while animating)
static std::wstring g_iv[8];
static ULONGLONG g_iv_t[8] = {};
static int g_setup_done[8] = { -1, -1, -1, -1, -1, -1, -1, -1 };
static std::wstring inst_ver(const Chapter& c) {
    int i = (c.num - 1) & 7;
    if (!g_iv_t[i] || GetTickCount64() - g_iv_t[i] > 1500) { g_iv[i] = installed_version(c); g_iv_t[i] = GetTickCount64(); }
    return g_iv[i];
}
static void iv_reset() { for (auto& t : g_iv_t) t = 0; }
static bool setup_done(const Chapter& c) {
    int i = (c.num - 1) & 7;
    if (g_setup_done[i] < 0) g_setup_done[i] = ini_get(sec_name(c).c_str(), L"SetupDone") == L"1" ? 1 : 0;
    return g_setup_done[i] == 1;
}

static void toast(const std::wstring& t) { g_toast = t; g_toast_until = GetTickCount64() + 4000; InvalidateRect(g_wnd, nullptr, FALSE); }
static Chapter& cur() { return g_ch[g_sel]; }

static void save_profile() {
    ini_set(L"Launcher", L"Name", g_prof.name);
    ini_set(L"Launcher", L"Color", g_prof.color);
    ini_set(L"Launcher", L"Code", g_prof.code);
    ini_set(L"Launcher", L"JoinCode", g_prof.join_code);
    ini_set(L"Launcher", L"Tab", std::to_wstring(g_prof.tab));
    if (g_page != Page::Welcome) ini_set(L"Launcher", L"Chapter", std::to_wstring(g_sel + 1));
}

// ------------------------------------------------------------------ colours
struct PlayerColor { const wchar_t* id; const wchar_t* label; COLORREF rgb; };
static const PlayerColor COLORS[] = {
    { L"yellow", L"Toy Yellow", RGB(245, 197, 24) }, { L"orange", L"Orange", RGB(255, 140, 26) },
    { L"pink", L"Pink", RGB(255, 95, 162) }, { L"purple", L"Purple", RGB(155, 92, 255) },
    { L"green", L"Green", RGB(61, 214, 107) }, { L"teal", L"Teal", RGB(34, 199, 192) },
    { L"blue", L"Blue", RGB(61, 139, 255) },
};
static COLORREF player_rgb(const std::wstring& id) {
    for (auto& c : COLORS) if (id == c.id) return c.rgb;
    return COLORS[0].rgb;
}

// launcher colour themes (Launcher settings page); the accent is the figure colour or one picked there
struct Theme { const wchar_t* id; const wchar_t* label; COLORREF bg, side, card, card2, line, text, dim, ok, warn, bad; };
static const Theme THEMES[] = {
    { L"dark", L"Dark", RGB(16, 17, 24), RGB(22, 24, 33), RGB(29, 31, 43), RGB(38, 41, 56), RGB(52, 56, 74),
      RGB(236, 237, 245), RGB(140, 145, 166), RGB(70, 210, 120), RGB(255, 170, 60), RGB(255, 90, 90) },
    { L"midnight", L"Midnight", RGB(5, 6, 10), RGB(10, 11, 18), RGB(16, 18, 28), RGB(25, 28, 42), RGB(38, 42, 60),
      RGB(232, 234, 248), RGB(125, 131, 160), RGB(70, 210, 120), RGB(255, 170, 60), RGB(255, 90, 90) },
    { L"light", L"Light", RGB(240, 241, 246), RGB(228, 230, 238), RGB(255, 255, 255), RGB(232, 234, 242), RGB(205, 209, 222),
      RGB(26, 28, 38), RGB(105, 110, 132), RGB(22, 150, 72), RGB(200, 110, 0), RGB(210, 50, 50) },
};
static COLORREF C_BG, C_SIDE, C_CARD, C_CARD2, C_LINE, C_TEXT, C_DIM, C_OK, C_WARN, C_BAD;
static const COLORREF C_RED = RGB(229, 57, 70);
static std::wstring g_theme = L"dark", g_accent_pref = L"figure";   // accent: "figure" or a colour id
static bool g_anims = true;
static void apply_theme() {
    const Theme* t = &THEMES[0];
    for (auto& th : THEMES) if (g_theme == th.id) t = &th;
    C_BG = t->bg; C_SIDE = t->side; C_CARD = t->card; C_CARD2 = t->card2; C_LINE = t->line;
    C_TEXT = t->text; C_DIM = t->dim; C_OK = t->ok; C_WARN = t->warn; C_BAD = t->bad;
}

static COLORREF mix(COLORREF a, COLORREF b, double t) {
    if (t < 0) t = 0;
    if (t > 1) t = 1;
    return RGB((int)(GetRValue(a) * (1 - t) + GetRValue(b) * t), (int)(GetGValue(a) * (1 - t) + GetGValue(b) * t),
               (int)(GetBValue(a) * (1 - t) + GetBValue(b) * t));
}

// ------------------------------------------------------------------ animation
// Every animated value is eased towards its target each frame; while anything still moves a 60 fps timer
// keeps repainting, otherwise the window only repaints on input (no idle CPU use).
static ULONGLONG g_frame_ms = 0;
static double g_dt = 0;
static bool g_moving = false;
static std::vector<std::pair<unsigned long long, double>> g_anim;   // small: a few dozen widgets
static double anim(unsigned long long key, double target, double speed = 14.0) {
    for (auto& a : g_anim) if (a.first == key) {
        if (!g_anims) { a.second = target; return target; }
        double k = 1.0 - exp(-speed * g_dt);
        a.second += (target - a.second) * k;
        if (fabs(target - a.second) < 0.002) a.second = target; else g_moving = true;
        return a.second;
    }
    g_anim.push_back({ key, target });
    return target;
}
static unsigned long long akey(int kind, int x, int y) { return ((unsigned long long)kind << 48) ^ ((unsigned long long)(x & 0xffffff) << 24) ^ (unsigned)(y & 0xffffff); }
static double ease(double t) { if (t <= 0) return 0; if (t >= 1) return 1; return 1 - pow(1 - t, 3); }

static COLORREF target_accent() { return player_rgb(g_accent_pref == L"figure" ? g_prof.color : g_accent_pref); }
// the accent fades over to a new colour instead of jumping
static COLORREF g_acc_from = 0, g_acc_to = 0;
static ULONGLONG g_acc_t0 = 0;
static COLORREF accent();
// accent used as text: a darker shade on the light theme so yellow/teal stay readable
static COLORREF acc_text() { return g_theme == L"light" ? mix(accent(), RGB(0, 0, 0), 0.38) : accent(); }
static COLORREF accent() {
    COLORREF t = target_accent();
    if (t != g_acc_to) { g_acc_from = g_acc_t0 ? mix(g_acc_from, g_acc_to, ease((g_frame_ms - g_acc_t0) / 300.0)) : t; g_acc_to = t; g_acc_t0 = g_frame_ms; }
    double k = g_anims ? ease((g_frame_ms - g_acc_t0) / 300.0) : 1;
    if (k < 1) g_moving = true;
    return mix(g_acc_from, g_acc_to, k);
}
static COLORREF on_color(COLORREF c) {   // readable text on a coloured button
    return (GetRValue(c) * 299 + GetGValue(c) * 587 + GetBValue(c) * 114) / 1000 > 150 ? RGB(20, 20, 28) : RGB(255, 255, 255);
}

// ------------------------------------------------------------------ fonts
static std::wstring g_face = L"Segoe UI";
static HFONT F_LOGO, F_H1, F_H2, F_BODY, F_SMALL, F_BOLD, F_CODE, F_BIG;
static void make_fonts() {
    // Windows: Segoe UI. Wine / Proton report a "Segoe UI" but draw it with a serif font, so there Tahoma
    // (shipped with Wine and Proton) is used - same as the Launcher 2 Linux build.
    bool wine = GetProcAddress(GetModuleHandleW(L"ntdll.dll"), "wine_get_version") != nullptr;
    g_face = wine ? L"Tahoma" : L"Segoe UI";
    auto mk = [](int px, int weight) {
        return CreateFontW(-S(px), 0, 0, 0, weight, 0, 0, 0, DEFAULT_CHARSET, 0, 0, CLEARTYPE_QUALITY, 0, g_face.c_str());
    };
    F_LOGO = mk(26, FW_BLACK); F_H1 = mk(30, FW_BOLD); F_H2 = mk(15, FW_BOLD); F_BODY = mk(14, FW_NORMAL);
    F_SMALL = mk(12, FW_NORMAL); F_BOLD = mk(14, FW_BOLD); F_CODE = mk(36, FW_BOLD); F_BIG = mk(20, FW_BOLD);
}

// ------------------------------------------------------------------ immediate-mode drawing + click areas
struct Hit { RECT r; std::function<void()> fn; bool hand; };
static std::vector<Hit> g_hits;
static POINT g_mouse = { -1, -1 };
static int g_pressed = -1;
static HDC g_dc;

static bool hover(const RECT& r) { return PtInRect(&r, g_mouse) != 0; }
static RECT R(int x, int y, int w, int h) { return { S(x), S(y), S(x + w), S(y + h) }; }
static void fill(const RECT& r, COLORREF c, int radius = 0) {
    HBRUSH b = CreateSolidBrush(c);
    if (radius <= 0) { FillRect(g_dc, &r, b); DeleteObject(b); return; }
    HPEN p = CreatePen(PS_SOLID, 1, c);
    HGDIOBJ ob = SelectObject(g_dc, b), op = SelectObject(g_dc, p);
    RoundRect(g_dc, r.left, r.top, r.right, r.bottom, S(radius * 2), S(radius * 2));
    SelectObject(g_dc, ob); SelectObject(g_dc, op);
    DeleteObject(b); DeleteObject(p);
}
static void frame(const RECT& r, COLORREF c, int radius, int width = 1) {
    HPEN p = CreatePen(PS_SOLID, S(width), c);
    HGDIOBJ op = SelectObject(g_dc, p), ob = SelectObject(g_dc, GetStockObject(NULL_BRUSH));
    RoundRect(g_dc, r.left, r.top, r.right, r.bottom, S(radius * 2), S(radius * 2));
    SelectObject(g_dc, op); SelectObject(g_dc, ob);
    DeleteObject(p);
}
static void circle(int cx, int cy, int rad, COLORREF c) {
    HBRUSH b = CreateSolidBrush(c); HPEN p = CreatePen(PS_SOLID, 1, c);
    HGDIOBJ ob = SelectObject(g_dc, b), op = SelectObject(g_dc, p);
    Ellipse(g_dc, S(cx - rad), S(cy - rad), S(cx + rad), S(cy + rad));
    SelectObject(g_dc, ob); SelectObject(g_dc, op);
    DeleteObject(b); DeleteObject(p);
}
static void text(const RECT& r, const std::wstring& s, HFONT f, COLORREF c, UINT flags = DT_LEFT | DT_TOP | DT_WORDBREAK) {
    SelectObject(g_dc, f);
    SetTextColor(g_dc, c);
    RECT rr = r;
    DrawTextW(g_dc, s.c_str(), (int)s.size(), &rr, flags | DT_NOPREFIX);
}
static int text_w(const std::wstring& s, HFONT f) {
    SelectObject(g_dc, f);
    SIZE sz; GetTextExtentPoint32W(g_dc, s.c_str(), (int)s.size(), &sz);
    return (int)(sz.cx / g_s);
}
static void click(const RECT& r, std::function<void()> fn) { g_hits.push_back({ r, std::move(fn), true }); }

enum class Btn { Primary, Secondary, Ghost, Danger };
static void button(int x, int y, int w, int h, const std::wstring& label, Btn style, std::function<void()> fn, bool enabled = true) {
    RECT r = R(x, y, w, h);
    bool hv = enabled && hover(r);
    double t = anim(akey(1, x, y), hv ? 1.0 : 0.0, 16);
    COLORREF bg, fg;
    switch (style) {
    case Btn::Primary: bg = accent(); fg = on_color(bg); break;
    case Btn::Danger: bg = C_RED; fg = RGB(255, 255, 255); break;
    case Btn::Ghost: bg = C_CARD; fg = C_TEXT; break;
    default: bg = C_CARD2; fg = C_TEXT; break;
    }
    if (!enabled) { bg = mix(bg, C_BG, 0.6); fg = mix(fg, C_BG, 0.5); }
    else {
        bg = mix(bg, style == Btn::Primary || style == Btn::Danger ? RGB(255, 255, 255) : C_TEXT, 0.12 * t);
        if (hv && (GetKeyState(VK_LBUTTON) & 0x8000)) bg = mix(bg, RGB(0, 0, 0), 0.12);   // pressed
    }
    fill(r, bg, 8);
    if (style == Btn::Ghost) frame(r, mix(C_LINE, accent(), t), 8);
    text(r, label, style == Btn::Primary ? F_BOLD : F_BODY, fg, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
    if (enabled) click(r, std::move(fn));
}

// a single-line text box; the focused one gets the keyboard (WM_CHAR)
struct Field { std::wstring* value; size_t max; bool code; };
static Field g_focus = { nullptr, 0, false };
static bool g_caret_on = true;
static void textbox(int x, int y, int w, int h, std::wstring* value, size_t max, bool code, const std::wstring& placeholder, HFONT f) {
    RECT r = R(x, y, w, h);
    bool focused = g_focus.value == value;
    double ft = anim(akey(7, x, y), focused ? 1.0 : 0.0, 16), ht = anim(akey(8, x, y), hover(r) ? 1.0 : 0.0, 16);
    fill(r, C_BG, 8);
    frame(r, mix(mix(C_LINE, C_DIM, ht), accent(), ft), 8, ft > 0.5 ? 2 : 1);
    RECT tr = { r.left + S(14), r.top, r.right - S(10), r.bottom };
    if (value->empty() && !focused) text(tr, placeholder, f, mix(C_DIM, C_BG, 0.3), DT_LEFT | DT_VCENTER | DT_SINGLELINE);
    else text(tr, *value, f, C_TEXT, DT_LEFT | DT_VCENTER | DT_SINGLELINE);
    if (focused && g_caret_on) {
        int cx = tr.left + S(text_w(*value, f)) + S(1);
        RECT c = { cx, r.top + S(10), cx + S(2), r.bottom - S(10) };
        fill(c, accent());
    }
    click(r, [=] { g_focus = { value, max, code }; g_caret_on = true; });
}

static void badge(int x, int y, const wchar_t* label) {
    COLORREF c = !label ? C_DIM : (wcscmp(label, L"READY") == 0 ? C_OK : C_WARN);
    std::wstring t = tr(label ? label : L"SOON");
    int w = text_w(t, F_SMALL) + 14;
    RECT r = R(x, y, w, 18);
    fill(r, mix(c, C_BG, 0.75), 9);
    text(r, t, F_SMALL, c, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
}

// ------------------------------------------------------------------ actions
static void start_install(int ch, bool then_launch);
static void do_play();
static void open_logs();
static void set_experimental(bool on);

static void copy_text(const std::wstring& s) {
    if (!OpenClipboard(g_wnd)) return;
    EmptyClipboard();
    HGLOBAL h = GlobalAlloc(GMEM_MOVEABLE, (s.size() + 1) * sizeof(wchar_t));
    if (h) {
        memcpy(GlobalLock(h), s.c_str(), (s.size() + 1) * sizeof(wchar_t));
        GlobalUnlock(h);
        SetClipboardData(CF_UNICODETEXT, h);
    }
    CloseClipboard();
}
static std::wstring clipboard_text() {
    std::wstring s;
    if (!OpenClipboard(g_wnd)) return s;
    HANDLE h = GetClipboardData(CF_UNICODETEXT);
    if (h) { const wchar_t* p = (const wchar_t*)GlobalLock(h); if (p) s = p; GlobalUnlock(h); }
    CloseClipboard();
    return s;
}

static void browse_folder(Chapter& c) {
    IFileOpenDialog* dlg = nullptr;
    if (FAILED(CoCreateInstance(CLSID_FileOpenDialog, nullptr, CLSCTX_ALL, IID_PPV_ARGS(&dlg)))) return;
    DWORD opts; dlg->GetOptions(&opts);
    dlg->SetOptions(opts | FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM);
    std::wstring title = L"Select your Poppy Playtime Chapter " + std::to_wstring(c.num) + L" folder";
    dlg->SetTitle(title.c_str());
    if (SUCCEEDED(dlg->Show(g_wnd))) {
        IShellItem* it = nullptr;
        if (SUCCEEDED(dlg->GetResult(&it))) {
            PWSTR p = nullptr;
            if (SUCCEEDED(it->GetDisplayName(SIGDN_FILESYSPATH, &p))) {
                c.dir = normalize_dir(c, p);
                bind_dir(c);
                c.state = check_dir(c, c.dir);
                if (dir_usable(c.state)) ini_set(L"Launcher", c.ini_key, c.dir);
                CoTaskMemFree(p);
            }
            it->Release();
        }
    }
    dlg->Release();
}

// "Speedrun mode" switched on: set the other switches to what a run needs (the mod forces the same values
// while speedrun=true, so a friend's other switches can't slow it down); switched off: back to the defaults
static void speedrun_preset(Chapter& c, int changed) {
    if (std::wstring(c.sync[changed].id) != L"speedrun") return;
    bool on = c.sync[changed].value;
    static const wchar_t* ON_IDS[] = { L"sync_activations", L"sync_destroy", L"sync_inventory", L"sync_hands", L"low_gfx" };
    std::vector<SyncOpt> def = default_sync();
    for (size_t i = 0; i < c.sync.size(); i++) {
        if ((int)i == changed) continue;
        if (!on) { c.sync[i].value = def[i].value; continue; }
        bool v = false;
        for (auto id : ON_IDS) if (std::wstring(c.sync[i].id) == id) v = true;
        if (std::wstring(c.sync[i].id) == L"popups") v = true;    // joined / died messages stay
        c.sync[i].value = v;
    }
    toast(on ? tr(L"Speedrun mode on: only doors, inventory and hands are shared.") : tr(L"Speedrun mode off: default settings."));
}

static void apply_settings(Chapter& c) {
    chapter_save_settings(c);
    if (!inst_ver(c).empty()) {
        if (!write_mod_settings(c, g_prof)) toast(tr(L"Couldn't save the mod settings - close the game or run the launcher as administrator."));
        else if (g_running[g_sel]) toast(tr(L"Saved - takes effect next time you start the game."));
    }
}

// keys apply to every chapter (1.5): copy them over and rewrite each installed chapter's keybinds
static void apply_keys_everywhere(Chapter& src) {
    for (auto& ch : g_ch) {
        if (&ch == &src) continue;
        for (size_t i = 0; i < ch.keys.size() && i < src.keys.size(); i++) ch.keys[i].value = src.keys[i].value;
        if (playable(ch)) { chapter_save_settings(ch); if (!inst_ver(ch).empty()) write_mod_settings(ch, g_prof); }
    }
    apply_settings(src);
}

// ------------------------------------------------------------------ servers
static std::wstring srv_key(const Server& v) { return v.kind == SrvKind::Host ? L"host" : v.addr + L"|" + std::to_wstring(v.port); }
static const Probe* probe_of(const Server& v) {
    std::wstring k = srv_key(v);
    for (auto& p : g_probes) if (p.first == k) return &p.second;
    return nullptr;
}
static void load_servers() {
    g_servers.clear();
    g_servers.push_back({ SrvKind::Relay, L"PoppyCoop Relay", RELAY_URL, 27777, true });
    g_servers.push_back({ SrvKind::Host, L"Host on this PC", L"", 27777, true });
    int n = _wtoi(ini_get(L"Servers", L"Count", L"0").c_str());
    for (int i = 1; i <= n && i <= 8; i++) {
        Server v;
        if (!parse_server(ini_get(L"Servers", (L"Addr" + std::to_wstring(i)).c_str()), v)) continue;
        v.name = ini_get(L"Servers", (L"Name" + std::to_wstring(i)).c_str());
        if (v.name.empty()) v.name = v.addr;
        v.builtin = false;
        g_servers.push_back(v);
    }
    std::wstring sel = ini_get(L"Launcher", L"Server");
    g_srv = 0;
    for (int i = 0; i < (int)g_servers.size(); i++) if (srv_key(g_servers[i]) == sel) g_srv = i;
}
static void save_servers() {
    int n = 0;
    WritePrivateProfileStringW(L"Servers", nullptr, nullptr, g_ini.c_str());     // rewrite the section
    for (auto& v : g_servers) {
        if (v.builtin) continue;
        n++;
        ini_set(L"Servers", (L"Name" + std::to_wstring(n)).c_str(), v.name);
        ini_set(L"Servers", (L"Addr" + std::to_wstring(n)).c_str(),
                v.kind == SrvKind::Relay ? v.addr : v.addr + L":" + std::to_wstring(v.port));
    }
    ini_set(L"Servers", L"Count", std::to_wstring(n));
    ini_set(L"Launcher", L"Server", srv_key(g_servers[g_srv]));
}
static void apply_server() {
    const Server& v = g_servers[g_srv];
    g_prof.srv_mode = v.kind == SrvKind::Host ? L"host" : L"join";
    g_prof.srv_addr = v.kind == SrvKind::Host ? L"127.0.0.1" : v.addr;
    g_prof.srv_port = v.port;
}

// measure in the background (all servers, or just the selected one), results come back as WM_APP_PROBE
struct ProbeResult { std::wstring key; Probe p; };
static void start_probe(bool all) {
    if (g_probing.exchange(true)) return;
    std::vector<Server> list;
    for (int i = 0; i < (int)g_servers.size(); i++)
        if ((all || i == g_srv) && g_servers[i].kind != SrvKind::Host) list.push_back(g_servers[i]);
    for (auto& v : list) {   // mark as "measuring"
        bool found = false;
        for (auto& p : g_probes) if (p.first == srv_key(v)) { found = true; }
        if (!found) g_probes.push_back({ srv_key(v), Probe() });
    }
    HWND w = g_wnd;
    std::thread([list, w] {
        for (auto& v : list) {
            auto* r = new ProbeResult{ srv_key(v), v.kind == SrvKind::Relay ? probe_relay(v.addr) : probe_direct(v.addr) };
            if (!PostMessageW(w, WM_APP_PROBE, 0, (LPARAM)r)) delete r;
        }
        g_probing = false;
        PostMessageW(w, WM_APP_PROBE, 1, 0);
    }).detach();
}

static COLORREF quality_color(int q) { return q >= 3 ? C_OK : q == 2 ? C_WARN : q == 1 ? C_BAD : C_DIM; }
// four signal bars; while measuring they light up one after another
static void signal_bars(int x, int y, const Probe* p, unsigned long long key) {
    bool measuring = !p || !p->done;
    int q = measuring ? 0 : quality(*p);
    double shown = anim(key, q, 10);
    for (int i = 0; i < 4; i++) {
        int bh = 6 + i * 4;
        COLORREF c = C_LINE;
        if (measuring) {
            int step = (int)(g_frame_ms / 180) % 5;
            if (i < step) c = mix(C_LINE, C_DIM, 0.6);
            if (g_anims) g_moving = true;
        } else if (shown >= i + 0.5) c = quality_color(q);
        fill(R(x + i * 6, y + 18 - bh, 4, bh), c, 1);
    }
}
static std::wstring probe_text(const Server& v, const Probe* p) {
    if (v.kind == SrvKind::Host) return tr(L"You are the server");
    if (!p || !p->done) return tr(L"Measuring...");
    if (p->ms < 0) return p->note.empty() ? L"Unreachable" : p->note;
    return std::to_wstring(p->ms) + L" ms  \x00B7  " + quality_label(quality(*p));
}

static void draw_server_card(int h) {
    RECT r = R(16, h - 52, 248, 46);
    bool on = g_page == Page::Servers;
    double ht = anim(akey(30, 0, 0), hover(r) ? 1.0 : 0.0, 16);
    fill(r, mix(mix(C_SIDE, C_CARD, ht), C_CARD2, on ? 1.0 : 0.0), 10);
    const Server& v = g_servers[g_srv];
    const Probe* p = probe_of(v);
    if (v.kind == SrvKind::Host) {
        for (int i = 0; i < 4; i++) fill(R(30 + i * 6, h - 39 + 18 - (6 + i * 4), 4, 6 + i * 4), C_OK, 1);
    } else signal_bars(30, h - 39, p, akey(31, 0, 0));
    text(R(64, h - 48, 196, 20), v.name, F_SMALL, C_TEXT, DT_LEFT | DT_SINGLELINE | DT_END_ELLIPSIS);
    std::wstring d = probe_text(v, p);
    if (p && p->done && !p->colo.empty()) d += L"  \x00B7  " + p->colo;
    text(R(64, h - 30, 196, 18), d, F_SMALL, C_DIM, DT_LEFT | DT_SINGLELINE | DT_END_ELLIPSIS);
    click(r, [] { g_page = Page::Servers; g_focus = {}; g_capture = -1; g_confirm_remove = -1; start_probe(true); });
}

// ------------------------------------------------------------------ sidebar
static void draw_sidebar(int h) {
    fill(R(0, 0, 280, h), C_SIDE);
    text(R(28, 26, 240, 30), tr(L"POPPY PLAYTIME"), F_LOGO, C_TEXT, DT_LEFT | DT_SINGLELINE);
    text(R(28, 56, 240, 30), tr(L"CO-OP"), F_LOGO, acc_text(), DT_LEFT | DT_SINGLELINE);

    // profile card
    RECT pc = R(16, 100, 248, 58);
    bool hv = hover(pc) || g_page == Page::Profile;
    fill(pc, hv ? C_CARD2 : C_CARD, 10);
    circle(44, 129, 13, player_rgb(g_prof.color));   // the figure colour, even with another accent
    std::wstring nm = g_prof.name.empty() ? L"Set your name" : g_prof.name;
    text(R(66, 110, 180, 20), nm, F_BOLD, g_prof.name.empty() ? C_WARN : C_TEXT, DT_LEFT | DT_SINGLELINE | DT_END_ELLIPSIS);
    text(R(66, 130, 180, 18), tr(L"Name & colour  \x203A"), F_SMALL, C_DIM, DT_LEFT | DT_SINGLELINE);
    click(pc, [] { g_page = Page::Profile; g_edit_name = g_prof.name; g_focus = { &g_edit_name, 24, false }; });

    text(R(28, 180, 200, 18), tr(L"CHAPTERS"), F_SMALL, C_DIM, DT_LEFT | DT_SINGLELINE);
    bool any_sel = g_page != Page::Welcome && g_page != Page::App;
    double bar = anim(akey(14, 0, 0), g_sel, 16), bar_a = anim(akey(15, 0, 0), any_sel ? 1.0 : 0.0, 14);
    for (int i = 0; i < (int)g_ch.size(); i++) {
        Chapter& c = g_ch[i];
        RECT r = R(16, 202 + i * 62, 248, 56);
        bool sel = i == g_sel && g_page != Page::Welcome && g_page != Page::App;
        double ht = anim(akey(12, i, 0), hover(r) ? 1.0 : 0.0, 16), st = anim(akey(13, i, 0), sel ? 1.0 : 0.0, 14);
        fill(r, mix(mix(C_SIDE, C_CARD, ht), C_CARD2, st), 10);
        COLORREF tc = playable(c) ? C_TEXT : C_DIM;
        text(R(32, 210 + i * 62, 160, 20), tr(L"Chapter ") + std::to_wstring(c.num), F_BOLD, tc, DT_LEFT | DT_SINGLELINE);
        std::wstring sub = c.title;
        if (playable(c)) {
            if (g_running[i]) sub = L"In game";
            else if (!dir_usable(c.state) || (inst_ver(c).empty() && !setup_done(c))) sub = L"Not set up yet";
            else if (inst_ver(c).empty()) sub = L"Installs when you play";
            else if (inst_ver(c) != MOD_VERSION) sub = L"Update ready";
        }
        text(R(32, 230 + i * 62, 170, 18), tr(sub), F_SMALL, g_running[i] ? C_OK : C_DIM, DT_LEFT | DT_SINGLELINE | DT_END_ELLIPSIS);
        badge(200, 211 + i * 62, badge_of(c));
        click(r, [i] { g_sel = i; g_page = Page::Chapter; g_focus = {}; g_capture = -1; g_confirm_uninstall = false; save_profile(); });
    }

    if (bar_a > 0.02) fill(R(16, 214 + (int)(bar * 62 + 0.5), 4, 32), mix(C_SIDE, accent(), bar_a), 2);

    // launcher settings (colours, animations)
    {
        if (FEATURE_ONLINE) {   // friends
            RECT fr = R(16, h - 138, 248, 36);
            bool fon = g_page == Page::Friends;
            double fht = anim(akey(17, 0, 0), hover(fr) ? 1.0 : 0.0, 16);
            fill(fr, mix(mix(C_SIDE, C_CARD, fht), C_CARD2, fon ? 1.0 : 0.0), 10);
            std::wstring lbl = tr(L"Friends");
            if (!g_fnet.incoming.empty()) lbl += L" (" + std::to_wstring(g_fnet.incoming.size()) + tr(L" new") + L")";
            else if (g_fnet_state == 1 && !g_fnet.friends.empty()) {
                int on = 0;
                for (auto& f : g_fnet.friends) if (f.online) on++;
                lbl += L" (" + std::to_wstring(on) + tr(L" online") + L")";
            } else if (g_fnet_state != 1 && !g_friends.empty()) lbl += L" (" + std::to_wstring(g_friends.size()) + L")";
            text(R(32, h - 138, 220, 36), lbl, F_SMALL, fon ? C_TEXT : mix(C_DIM, C_TEXT, fht), DT_LEFT | DT_VCENTER | DT_SINGLELINE);
            click(fr, [] {
                g_page = Page::Friends; g_capture = -1; g_focus = { &g_friend_edit, FRIEND_NAME_MAX + 6, false }; friends_refresh();
                if (!friends_used()) { ini_set(L"Launcher", L"FriendsOn", L"1"); g_friends_on = 1; }
                friends_net_sync(GetTickCount64() - g_fnet_hello_at > 15000 || g_fnet_hello_at == 0);
            });
        }
        RECT r = R(16, h - 98, 248, 36);
        bool on = g_page == Page::App;
        double ht = anim(akey(16, 0, 0), hover(r) ? 1.0 : 0.0, 16);
        fill(r, mix(mix(C_SIDE, C_CARD, ht), C_CARD2, on ? 1.0 : 0.0), 10);
        text(R(32, h - 98, 220, 36), tr(L"Launcher settings"), F_SMALL, on ? C_TEXT : mix(C_DIM, C_TEXT, ht), DT_LEFT | DT_VCENTER | DT_SINGLELINE);
        click(r, [] { g_page = Page::App; g_focus = {}; g_capture = -1; });
    }

    // server + connection quality (click: Servers page)
    draw_server_card(h);
}

// ------------------------------------------------------------------ problem report
static std::wstring system_summary() {
    std::wstring s = L"PoppyCoop mod v" MOD_VERSION L", launcher " LAUNCHER_VERSION L"\r\n";
    typedef LONG(WINAPI* RtlGetVersionFn)(OSVERSIONINFOW*);
    OSVERSIONINFOW vi = { sizeof vi };
    auto rgv = (RtlGetVersionFn)GetProcAddress(GetModuleHandleW(L"ntdll.dll"), "RtlGetVersion");
    if (rgv && rgv(&vi) == 0) s += L"Windows " + std::to_wstring(vi.dwMajorVersion) + L"." + std::to_wstring(vi.dwMinorVersion) + L" build " + std::to_wstring(vi.dwBuildNumber) + L"\r\n";
    if (GetProcAddress(GetModuleHandleW(L"ntdll.dll"), "wine_get_version")) s += L"(running under Wine / Proton)\r\n";
    MEMORYSTATUSEX ms = { sizeof ms };
    if (GlobalMemoryStatusEx(&ms)) s += L"RAM " + std::to_wstring((unsigned)(ms.ullTotalPhys >> 20)) + L" MB\r\n";
    SYSTEM_INFO si; GetNativeSystemInfo(&si);
    s += L"CPU threads " + std::to_wstring(si.dwNumberOfProcessors) + L"\r\n";
    DISPLAY_DEVICEW dd = { sizeof dd };
    for (DWORD i = 0; EnumDisplayDevicesW(nullptr, i, &dd, 0); i++)
        if (dd.StateFlags & DISPLAY_DEVICE_PRIMARY_DEVICE) { s += L"GPU " + std::wstring(dd.DeviceString) + L"\r\n"; break; }
    return s;
}
// returns the zip path (on the desktop) or "" when Windows' tar isn't there (old Windows, Wine)
// the game's newest crash report (%LOCALAPPDATA%\\<Project>\\Saved\\Crashes\\<id>\\): call stack + minidump
static void copy_newest_crash(const Chapter& ch, const std::wstring& to, const std::wstring& crash_dir = L"") {
    CrashInfo ci;
    if (!crash_dir.empty()) ci.dir = crash_dir;
    else if (!newest_crash(ch, ci)) return;
    for (const wchar_t* f : { L"CrashContext.runtime-xml", L"UE4Minidump.dmp", L"UEMinidump.dmp" })
        CopyFileW((ci.dir + f).c_str(), (to + L"\\crash_" + f).c_str(), FALSE);
}

// Automatic crash reports: a crash report folder newer than the last one sent (and not older than 3 days)
// is sent once, in the background. Only with the player's consent (g_crashrep == 1).
static void maybe_report_crashes() {
    if (!FEATURE_ONLINE) return;
    if (g_crashrep != 1) return;
    for (size_t i = 0; i < g_ch.size() && i < 8; i++) {
        const Chapter& ch = g_ch[i];
        if (!playable(ch) || ch.dir.empty() || g_running[i]) continue;
        CrashInfo ci;
        if (!newest_crash(ch, ci)) continue;
        std::wstring key = L"LastCrashSent" + std::to_wstring(ch.num);
        ULONGLONG last = _wcstoui64(ini_get(L"Launcher", key.c_str(), L"0").c_str(), nullptr, 10);
        if (ci.time <= last || now_ft() - ci.time > REPORT_MAX_AGE) continue;
        ini_set(L"Launcher", key.c_str(), std::to_wstring(ci.time));        // once, even if sending fails
        std::wstring ver = inst_ver(ch).empty() ? std::wstring(MOD_VERSION) : inst_ver(ch);
        // when it crashed and when it is sent: a report waits until the launcher is opened again (could be days)
        auto ft_utc = [](ULONGLONG t) {
            FILETIME f = { (DWORD)(t & 0xFFFFFFFF), (DWORD)(t >> 32) };
            SYSTEMTIME st = {};
            FileTimeToSystemTime(&f, &st);
            wchar_t b[32];
            swprintf(b, 32, L"%02u.%02u. %02u:%02u", st.wDay, st.wMonth, st.wHour, st.wMinute);
            return std::wstring(b);
        };
        std::wstring os = L"Crashed " + ft_utc(ci.time) + L" UTC, sent " + ft_utc(now_ft()) + L" UTC\n" + system_summary();
        std::thread([w = g_wnd, ch, ci, ver, os] {
            std::string err;
            bool ok = send_crash_report(ch, ci, ver, os, err);
            PostMessageW(w, WM_APP_CRASHSENT, ok ? 1 : 0, 0);
        }).detach();
    }
}
// first start: ask once whether crash reports may be sent (changeable in the launcher settings) - a card in the
// launcher drawn over the page (paint calls it last), not a Windows message box
static void set_crash_consent(bool yes) {
    g_crashrep = yes ? 1 : 0;
    ini_set(L"Launcher", L"CrashReports", yes ? L"1" : L"0");
    if (yes) maybe_report_crashes();
}

// Windows: the desktop. Wine / Proton: the desktop is hidden inside the Wine prefix - the launcher's own folder
// is where a Linux / Steam Deck player finds the zip.
static bool running_on_wine() { return GetProcAddress(GetModuleHandleW(L"ntdll.dll"), "wine_get_version") != nullptr; }
static std::wstring report_zip_folder() {
    wchar_t p[MAX_PATH];
    if (!running_on_wine() && SUCCEEDED(SHGetFolderPathW(nullptr, CSIDL_DESKTOPDIRECTORY, nullptr, 0, p))) return p;
    DWORD n = GetModuleFileNameW(nullptr, p, MAX_PATH);
    std::wstring exe(p, n);
    return exe.substr(0, exe.find_last_of(L"\\"));
}
static std::wstring make_report_zip(const Chapter& ch, const std::wstring& log, const std::wstring& crash_dir = L"") {
    wchar_t tmp[MAX_PATH];
    if (!GetTempPathW(MAX_PATH, tmp)) return L"";
    std::wstring dir = std::wstring(tmp) + L"PoppyCoopReport";
    delete_tree(dir);
    CreateDirectoryW(dir.c_str(), nullptr);
    CopyFileW(log.c_str(), (dir + L"\\UE4SS.log").c_str(), FALSE);
    CopyFileW((bin_dir(ch) + L"\\ue4ss\\UE4SS_previous.log").c_str(), (dir + L"\\UE4SS_previous.log").c_str(), FALSE);
    copy_newest_crash(ch, dir, crash_dir);
    std::wstring mod = bin_dir(ch) + L"\\ue4ss\\Mods\\PoppyCoop\\";
    {   // network helper logs (queue full / timeouts)
        WIN32_FIND_DATAW fd;
        HANDLE h = FindFirstFileW((mod + L"net_*.log").c_str(), &fd);
        if (h != INVALID_HANDLE_VALUE) {
            do CopyFileW((mod + fd.cFileName).c_str(), (dir + L"\\" + fd.cFileName).c_str(), FALSE); while (FindNextFileW(h, &fd));
            FindClose(h);
        }
    }
    for (const wchar_t* f : { L"config.txt", L"keybinds.txt", L"bugreport.txt" }) CopyFileW((mod + f).c_str(), (dir + L"\\" + f).c_str(), FALSE);
    std::wstring info = system_summary() + L"Chapter " + std::to_wstring(ch.num) + L", installed mod v" + inst_ver(ch) + L"\r\nGame folder " + ch.dir + L"\r\n";
    std::string u8;
    for (wchar_t c : info) u8 += c < 128 ? (char)c : '?';
    HANDLE f = CreateFileW((dir + L"\\system.txt").c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, 0, nullptr);
    if (f != INVALID_HANDLE_VALUE) { DWORD w; WriteFile(f, u8.data(), (DWORD)u8.size(), &w, nullptr); CloseHandle(f); }
    std::wstring zip = report_zip_folder() + L"\\PoppyCoop_report.zip";
    bool ok = zip_folder(dir, zip);
    delete_tree(dir);
    return ok ? zip : L"";
}

// ------------------------------------------------------------------ chapter page parts
static const int MX = 312;   // main area x
static int MW = 636;         // main area width - grows with the window (set in paint)
// window: layout space at 1x is at least 980x640; up to 1180x780 the layout gets more room, a bigger window zooms
static const int MIN_W = 980, MIN_H = 640, BASE_W = 1180, BASE_H = 780;

static void draw_colors(int x, int y) {
    for (int i = 0; i < 7; i++) {
        int cx = x + 18 + i * 46;
        bool sel = g_prof.color == COLORS[i].id;
        RECT r = R(cx - 18, y, 36, 36);
        double st = anim(akey(9, cx, y), sel ? 1.0 : 0.0, 16), ht = anim(akey(10, cx, y), hover(r) ? 1.0 : 0.0, 16);
        if (st > 0.02) { circle(cx, y + 18, 12 + (int)(6 * st + 0.5), mix(C_CARD, C_TEXT, st)); circle(cx, y + 18, 12 + (int)(3 * st + 0.5), C_CARD); }
        else if (ht > 0.02) circle(cx, y + 18, 12 + (int)(5 * ht + 0.5), mix(C_CARD, C_LINE, ht));
        circle(cx, y + 18, 12, COLORS[i].rgb);
        std::wstring id = COLORS[i].id;
        click(r, [id] { g_prof.color = id; save_profile(); });
    }
}

static std::wstring dir_message(const Chapter& c, COLORREF& col) {
    switch (c.state) {
    case DirState::Ok: col = C_OK; return c.needs_ue5 ? L"Chapter 1 v1.3 found (Unreal Engine 5)" : L"Chapter " + std::to_wstring(c.num) + L" found";
    case DirState::OkUnknownVersion: col = C_OK; return tr(L"Poppy Playtime found (version couldn't be checked)");
    case DirState::OldVersion: col = C_BAD; return tr(L"This is the old Chapter 1 - update it to v1.3 in Steam first");
    case DirState::NotFound: col = C_BAD; return tr(L"Chapter ") + std::to_wstring(c.num) + tr(L" isn't in that folder");
    default: col = C_DIM; return tr(L"No folder selected yet - click Browse");
    }
}

// a primary button that fills up while the mod installs
static void progress_button(int x, int y, int w, int h, const std::wstring& label) {
    double p = anim(akey(6, 0, 0), g_install_pct / 100.0, 8);
    RECT r = R(x, y, w, h);
    fill(r, mix(accent(), C_BG, 0.65), 8);
    if (p > 0.01) fill(R(x, y, std::max(16, (int)(w * p)), h), accent(), 8);
    text(r, label + L" " + std::to_wstring((int)(p * 100 + 0.5)) + L"%", F_BOLD, p > 0.5 ? on_color(accent()) : C_TEXT,
         DT_CENTER | DT_VCENTER | DT_SINGLELINE);
}

static void search_again(Chapter& c) {
    Detect d = detect_game(c);
    c.detect = (int)d.what;
    if (d.what == Found::Ok) {
        c.dir = d.dir; c.found_where = d.where; bind_dir(c); c.state = check_dir(c, c.dir);
        ini_set(L"Launcher", c.ini_key, c.dir);
        toast(tr(L"Found Chapter ") + std::to_wstring(c.num) + tr(L" in your ") + d.where + L".");
    } else if (d.what == Found::OldVersion) {
        c.dir = d.dir; c.found_where = d.where; c.state = check_dir(c, c.dir);
        toast(tr(L"Only found the old Chapter 1 - co-op needs v1.3."));
    } else toast(tr(L"Still not found - choose the folder yourself."));
}

static void draw_folder_row(Chapter& c, int y) {
    RECT box = R(MX, y, MW - 130, 40);
    fill(box, C_BG, 8); frame(box, C_LINE, 8);
    std::wstring shown = c.dir.empty() ? L"No folder selected" : c.dir;
    text({ box.left + S(14), box.top, box.right - S(10), box.bottom }, shown, F_SMALL, c.dir.empty() ? C_DIM : C_TEXT,
         DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_PATH_ELLIPSIS);
    Chapter* pc = &c;
    button(MX + MW - 118, y, 118, 40, tr(L"Browse"), Btn::Secondary, [pc] { browse_folder(*pc); pc->found_where.clear(); });
    COLORREF col;
    std::wstring m = dir_message(c, col);
    if (dir_usable(c.state) && !c.found_where.empty()) m += L" - found automatically (" + c.found_where + L")";
    circle(MX + 6, y + 58, 4, col);
    text(R(MX + 18, y + 49, MW - 18, 20), m, F_SMALL, col, DT_LEFT | DT_SINGLELINE | DT_END_ELLIPSIS);
}

// nothing found anywhere: say so, show where we looked, let the player pick the folder
static void draw_not_found(Chapter& c, int y) {
    g_view = 3;
    RECT card = R(MX - 16, y, MW + 32, 330);
    fill(card, C_CARD, 14);
    text(R(MX, y + 18, MW, 20), tr(L"SET UP CHAPTER ") + std::to_wstring(c.num), F_SMALL, acc_text(), DT_LEFT | DT_SINGLELINE);
    circle(MX + 12, y + 56, 12, mix(C_CARD, C_WARN, 0.25));
    text(R(MX, y + 44, 24, 24), L"?", F_BOLD, C_WARN, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
    text(R(MX + 36, y + 42, MW - 36, 28), tr(L"Chapter ") + std::to_wstring(c.num) + tr(L" wasn't found automatically"), F_BIG, C_TEXT, DT_LEFT | DT_SINGLELINE);
    text(R(MX, y + 84, MW, 40), tr(L"The launcher looked in all your Steam libraries and in Steam's download folder - a version "
         L"downloaded with the Steam console (downpatch) always ends up there:"), F_SMALL, C_DIM);
    std::wstring depot = *c.appid ? L"steamapps\\content\\app_" + std::wstring(c.appid) + L"\\depot_" + std::to_wstring(_wtoi(c.appid) + 1)
                                  : L"steamapps\\common\\" + std::wstring(c.steam_folder);
    RECT pr = R(MX, y + 126, MW, 34);
    fill(pr, C_BG, 8);
    text(R(MX + 14, y + 126, MW - 28, 34), L"Steam\\" + depot, F_SMALL, C_TEXT, DT_LEFT | DT_VCENTER | DT_SINGLELINE);
    text(R(MX, y + 172, MW, 40), tr(L"If the game is somewhere else (another drive, a copied folder), choose the folder that contains ") + (c.experimental ? tr(L"the game's .exe") : c.exe) + tr(L" yourself."), F_SMALL, C_DIM);
    Chapter* pc = &c;
    button(MX + MW - 220, y + 270, 220, 44, tr(L"Choose folder..."), Btn::Primary, [pc] { browse_folder(*pc); pc->found_where.clear(); });
    button(MX + MW - 380, y + 270, 148, 44, tr(L"Search again"), Btn::Ghost, [pc] { search_again(*pc); });
}

static void draw_setup(Chapter& c, int y) {
    if (c.dir.empty()) { draw_not_found(c, y); return; }
    g_view = 2;
    RECT card = R(MX - 16, y, MW + 32, 330);
    fill(card, C_CARD, 14);
    text(R(MX, y + 18, MW, 20), tr(L"SET UP CHAPTER ") + std::to_wstring(c.num), F_SMALL, acc_text(), DT_LEFT | DT_SINGLELINE);
    bool found = dir_usable(c.state);
    text(R(MX, y + 38, MW, 26), found ? tr(L"Chapter ") + std::to_wstring(c.num) + tr(L" is ready to be set up")
                                      : L"Where is Chapter " + std::to_wstring(c.num) + L" installed?", F_BIG, C_TEXT, DT_LEFT | DT_SINGLELINE);
    std::wstring tip = c.needs_ue5 ? L"Co-op needs Chapter 1 version 1.3 (the current Steam version). " : L"";
    tip += found ? tr(L"Is this the right folder? If not, pick another one with Browse.")
                 : L"Pick the folder that contains " + (c.experimental ? tr(L"the game's .exe") : c.exe) + L" (Steam > right-click the game > Manage > Browse local files).";
    text(R(MX, y + 68, MW, 40), tip, F_SMALL, C_DIM);
    draw_folder_row(c, y + 114);

    int by = y + 200;
    text(R(MX, by, 300, 20), tr(L"What should other players call you?"), F_BOLD, C_TEXT, DT_LEFT | DT_SINGLELINE);
    textbox(MX, by + 24, 300, 40, &g_prof.name, 24, false, L"Your name", F_BODY);
    draw_colors(MX + 320, by + 26);
    if (g_installing && g_install_ch == g_sel) { progress_button(MX + MW - 220, y + 270, 220, 44, L"Installing"); return; }
    bool ok = found && !trim(g_prof.name).empty() && !g_installing;
    int idx = g_sel;
    button(MX + MW - 220, y + 270, 220, 44, tr(L"Install co-op mod"), Btn::Primary, [idx] {
        g_prof.name = clean_name(g_prof.name); save_profile(); g_focus = {};
        if (game_running(g_ch[idx])) { toast(tr(L"Close Poppy Playtime first so the mod can be installed.")); return; }
        start_install(idx, false);
    }, ok);
}

static std::vector<std::wstring> recent_codes();
static std::wstring played_with(const std::wstring& code);
static void draw_modes(int y) {
    const wchar_t* tabs[] = { L"Quick Play", L"Create Game", L"Join Game" };
    int tw = (MW - 16) / 3;
    double pos = anim(akey(3, 0, 0), g_prof.tab, 16);            // the highlight slides between the tabs
    for (int i = 0; i < 3; i++) {
        RECT r = R(MX + i * (tw + 8), y, tw, 42);
        fill(r, mix(C_CARD, C_CARD2, anim(akey(11, i, 0), hover(r) ? 1.0 : 0.0, 16)), 10);
    }
    fill(R(MX + (int)(pos * (tw + 8) + 0.5), y, tw, 42), accent(), 10);
    for (int i = 0; i < 3; i++) {
        RECT r = R(MX + i * (tw + 8), y, tw, 42);
        double on = 1.0 - std::min(1.0, fabs(pos - i));
        text(r, tr(tabs[i]), F_BOLD, mix(C_TEXT, on_color(accent()), on), DT_CENTER | DT_VCENTER | DT_SINGLELINE);
        click(r, [i] { g_prof.tab = i; g_focus = i == 2 ? Field{ &g_prof.join_code, 12, true } : Field{}; save_profile(); });
    }
    RECT card = R(MX, y + 54, MW, 150);
    fill(card, C_CARD, 14);
    int cy = y + 72;
    if (g_prof.tab == 0) {
        text(R(MX + 20, cy, MW - 40, 24), tr(L"Public lobby"), F_BIG, C_TEXT, DT_LEFT | DT_SINGLELINE);
        text(R(MX + 20, cy + 32, MW - 40, 60), tr(L"Jump straight in and play with anyone who's online right now. No code needed."), F_BODY, C_DIM);
    } else if (g_prof.tab == 1) {
        if (g_prof.code.empty()) { g_prof.code = new_code(); save_profile(); }
        text(R(MX + 20, cy, 300, 18), tr(L"YOUR ROOM CODE"), F_SMALL, C_DIM, DT_LEFT | DT_SINGLELINE);
        RECT cr = R(MX + 20, cy + 20, 260, 48);
        text(cr, g_prof.code, F_CODE, hover(cr) ? acc_text() : C_TEXT, DT_LEFT | DT_VCENTER | DT_SINGLELINE);
        click(cr, [] { copy_text(g_prof.code); toast(tr(L"Copied to clipboard!  Room code ") + g_prof.code); });
        button(MX + 300, cy + 4, 150, 36, tr(L"Copy code"), Btn::Secondary, [] { copy_text(g_prof.code); toast(tr(L"Copied to clipboard!  Room code ") + g_prof.code); });
        button(MX + 460, cy + 4, 156, 36, tr(L"Copy invite"), Btn::Secondary, [] {
            copy_text(L"Join my Poppy Playtime co-op game!\r\nRoom code: " + g_prof.code +
                      L"\r\nIn the PoppyCoop launcher pick Join Game and enter the code, or open this link: poppycoop://join/" + g_prof.code);
            toast(tr(L"Invite copied - paste it to your friends!"));
        });
        button(MX + 300, cy + 48, 150, 36, tr(L"New code"), Btn::Ghost, [] { g_prof.code = new_code(); save_profile(); });
        text(R(MX + 20, cy + 96, MW - 40, 40), tr(L"Share the code or the invite. Friends pick Join Game and enter it."), F_SMALL, C_DIM);
    } else {
        text(R(MX + 20, cy, 300, 18), tr(L"FRIEND'S ROOM CODE"), F_SMALL, C_DIM, DT_LEFT | DT_SINGLELINE);
        textbox(MX + 20, cy + 22, 300, 48, &g_prof.join_code, 12, true, L"ABC123", F_BIG);
        button(MX + 336, cy + 28, 120, 36, tr(L"Paste"), Btn::Secondary, [] {
            std::wstring code = extract_code(clipboard_text());
            if (code.empty()) { toast(tr(L"No room code on the clipboard.")); return; }
            g_prof.join_code = code; save_profile(); toast(tr(L"Pasted room code ") + code);
        });
        auto rc = recent_codes();
        if (rc.empty())
            text(R(MX + 20, cy + 84, MW - 40, 40), tr(L"Ask your friend for their code, or just open the invite link they sent you."), F_SMALL, C_DIM);
        else {
            text(R(MX + 20, cy + 82, 70, 30), tr(L"Recent:"), F_SMALL, C_DIM, DT_LEFT | DT_VCENTER | DT_SINGLELINE);
            int x = MX + 90;
            for (auto& code : rc) {
                button(x, cy + 82, 100, 30, code, code == g_prof.join_code ? Btn::Primary : Btn::Ghost, [code] { g_prof.join_code = code; save_profile(); });
                x += 108;
            }
            std::wstring with = played_with(g_prof.join_code);
            if (!with.empty()) text(R(MX + 20, cy + 116, MW - 40, 18), tr(L"Played with: ") + with, F_SMALL, C_DIM, DT_LEFT | DT_SINGLELINE | DT_END_ELLIPSIS);
        }
    }
}

static void draw_play_bar(Chapter& c, int y) {
    // mod status (left) + play button (right)
    std::wstring iv = inst_ver(c), st;
    COLORREF col = C_OK;
    if (iv.empty()) { st = tr(L"Co-op mod not installed yet - it installs when you press Play"); col = C_WARN; }
    else if (iv != MOD_VERSION) { st = tr(L"Update available: v") + iv + L" to v" MOD_VERSION L" - installs when you press Play"; col = C_WARN; }
    else st = tr(L"Co-op mod v") + iv + tr(L" installed");
    circle(MX + 6, y + 13, 4, col);
    text(R(MX + 18, y + 3, MW - 260, 20), st, F_SMALL, col, DT_LEFT | DT_SINGLELINE | DT_END_ELLIPSIS);
    std::wstring room = g_prof.tab == 0 ? tr(L"Public lobby") : (g_prof.tab == 1 ? tr(L"Your room ") + g_prof.code : tr(L"Room ") + (g_prof.join_code.empty() ? L"-" : g_prof.join_code));
    text(R(MX + 18, y + 24, MW - 260, 20), tr(L"Playing as ") + g_prof.name + L"  \x00B7  " + room + L"  \x00B7  " + g_servers[g_srv].name, F_SMALL, C_DIM, DT_LEFT | DT_SINGLELINE | DT_END_ELLIPSIS);
    text(R(MX + 18, y + 44, MW - 260, 20), tr(L"F6 takes you to a friend - even to their later checkpoint."), F_SMALL, C_DIM, DT_LEFT | DT_SINGLELINE | DT_END_ELLIPSIS);

    std::wstring label = tr(L"PLAY");
    bool en = true;
    if (g_running[g_sel] && g_multi && !g_installing) label = tr(L"PLAY ANOTHER");
    else if (g_running[g_sel]) { label = L"IN GAME"; en = false; }
    else if (g_installing) { progress_button(MX + MW - 220, y, 220, 64, L"INSTALLING"); return; }
    else if (g_starting_ch == g_sel) { label = L"STARTING..."; en = false; }
    button(MX + MW - 220, y, 220, 64, label, Btn::Primary, [] { do_play(); }, en);
}

static void draw_chapter(int h) {
    Chapter& c = cur();
    text(R(MX, 28, 300, 18), tr(L"CHAPTER ") + std::to_wstring(c.num), F_SMALL, acc_text(), DT_LEFT | DT_SINGLELINE);
    text(R(MX, 46, MW - 280, 40), c.title, F_H1, C_TEXT, DT_LEFT | DT_SINGLELINE);
    badge(MX + text_w(c.title, F_H1) + 14, 60, badge_of(c));
    if (!playable(c)) {
        g_view = 1;
        RECT card = R(MX, 110, MW, 150);
        fill(card, C_CARD, 14);
        text(R(MX + 24, 132, MW - 48, 24), tr(L"Coming later"), F_BIG, C_TEXT, DT_LEFT | DT_SINGLELINE);
        if (c.experimental) {
            card = R(MX, 110, MW, 200); fill(card, C_CARD, 14);
            text(R(MX + 24, 132, MW - 48, 24), tr(L"Experimental"), F_BIG, C_TEXT, DT_LEFT | DT_SINGLELINE);
            text(R(MX + 24, 166, MW - 48, 60), tr(L"Full co-op for this chapter is still being built. You can already try it as experimental: you see each other, but doors, puzzles and items aren't shared."), F_BODY, C_DIM);
            button(MX + 24, 240, 300, 44, tr(L"Turn on experimental chapters"), Btn::Primary, [] { set_experimental(true); });
            return;
        }
        text(R(MX + 24, 166, MW - 48, 60), tr(L"Co-op for this chapter is still being built. It unlocks in a future update of the launcher."), F_BODY, C_DIM);
        return;
    }
    // the setup card stays until the player pressed "Install" once (or the mod is already there)
    bool ready = dir_usable(c.state) && !trim(g_prof.name).empty() && !(g_installing && g_install_ch == g_sel)
                 && (!inst_ver(c).empty() || setup_done(c));
    if (ready) {
        button(MX + MW - 130, 50, 130, 36, tr(L"Settings"), Btn::Ghost, [] { g_page = Page::Settings; g_focus = {}; g_capture = -1; g_confirm_uninstall = false; });
        button(MX + MW - 250, 50, 110, 36, tr(L"Logs"), Btn::Ghost, [] { open_logs(); });
    }
    text(R(MX, 98, MW, 44), tr(c.blurb), F_SMALL, C_DIM);
    if (!ready) { draw_setup(c, 152); return; }
    g_view = 4;
    draw_modes(156);
    draw_play_bar(c, h - 100);
}

// ------------------------------------------------------------------ welcome page (first start: nothing is set up yet)
static void draw_welcome(int h) {
    text(R(MX, 28, MW, 18), tr(L"WELCOME"), F_SMALL, acc_text(), DT_LEFT | DT_SINGLELINE);
    text(R(MX, 46, MW, 40), tr(L"Play Poppy Playtime together"), F_H1, C_TEXT, DT_LEFT | DT_SINGLELINE);
    text(R(MX, 96, MW, 40), tr(L"Pick the chapter you want to play. The launcher only asks for that chapter's game folder - you don't need the other chapters."), F_BODY, C_DIM);
    int cw = (MW - 16) / 2;
    for (int i = 0; i < 2; i++) {
        Chapter& c = g_ch[i];
        RECT r = R(MX + i * (cw + 16), 160, cw, 230);
        bool hv = hover(r);
        fill(r, hv ? C_CARD2 : C_CARD, 14);
        if (hv) frame(r, accent(), 14, 2);
        text(R(MX + i * (cw + 16) + 22, 182, cw - 44, 18), tr(L"CHAPTER ") + std::to_wstring(c.num), F_SMALL, acc_text(), DT_LEFT | DT_SINGLELINE);
        text(R(MX + i * (cw + 16) + 22, 202, cw - 44, 30), c.title, F_BIG, C_TEXT, DT_LEFT | DT_SINGLELINE);
        badge(MX + i * (cw + 16) + 22, 238, badge_of(c));
        text(R(MX + i * (cw + 16) + 22, 266, cw - 44, 90), tr(c.blurb), F_SMALL, C_DIM);
        std::wstring st = dir_usable(c.state) ? tr(L"Game found - ready to set up  \x203A") : tr(L"Set up  \x203A");
        text(R(MX + i * (cw + 16) + 22, 356, cw - 44, 20), st, F_BOLD, hv ? acc_text() : C_TEXT, DT_LEFT | DT_SINGLELINE);
        click(r, [i] { g_sel = i; g_page = Page::Chapter; save_profile(); });
    }
    text(R(MX, 410, MW, 40), tr(L"Chapters 3 to 5 can be tried as experimental (Launcher settings). You can set up another chapter any time from the list on the left."), F_SMALL, C_DIM);
    (void)h;
}

// ------------------------------------------------------------------ settings page
static const wchar_t* vk_name(UINT vk) {
    static wchar_t buf[16];
    if (vk >= 'A' && vk <= 'Z') { buf[0] = (wchar_t)vk; buf[1] = 0; return buf; }
    static const wchar_t* digits[] = { L"ZERO", L"ONE", L"TWO", L"THREE", L"FOUR", L"FIVE", L"SIX", L"SEVEN", L"EIGHT", L"NINE" };
    if (vk >= '0' && vk <= '9') return digits[vk - '0'];
    static const wchar_t* nums[] = { L"NUM_ZERO", L"NUM_ONE", L"NUM_TWO", L"NUM_THREE", L"NUM_FOUR", L"NUM_FIVE", L"NUM_SIX", L"NUM_SEVEN", L"NUM_EIGHT", L"NUM_NINE" };
    if (vk >= VK_NUMPAD0 && vk <= VK_NUMPAD9) return nums[vk - VK_NUMPAD0];
    if (vk >= VK_F1 && vk <= VK_F12) { swprintf(buf, 16, L"F%d", vk - VK_F1 + 1); return buf; }
    switch (vk) {
    case VK_SPACE: return L"SPACE"; case VK_TAB: return L"TAB"; case VK_BACK: return L"BACKSPACE"; case VK_RETURN: return L"RETURN";
    case VK_INSERT: return L"INS"; case VK_DELETE: return L"DEL"; case VK_HOME: return L"HOME"; case VK_END: return L"END";
    case VK_PRIOR: return L"PAGE_UP"; case VK_NEXT: return L"PAGE_DOWN"; case VK_LEFT: return L"LEFT_ARROW";
    case VK_RIGHT: return L"RIGHT_ARROW"; case VK_UP: return L"UP_ARROW"; case VK_DOWN: return L"DOWN_ARROW";
    case VK_MULTIPLY: return L"MULTIPLY"; case VK_ADD: return L"ADD"; case VK_SUBTRACT: return L"SUBTRACT";
    case VK_DECIMAL: return L"DECIMAL"; case VK_DIVIDE: return L"DIVIDE"; case VK_PAUSE: return L"PAUSE";
    }
    return nullptr;
}
static std::wstring key_label(const std::wstring& k) {
    static const struct { const wchar_t* a; const wchar_t* b; } nice[] = {
        { L"ZERO", L"0" }, { L"ONE", L"1" }, { L"TWO", L"2" }, { L"THREE", L"3" }, { L"FOUR", L"4" }, { L"FIVE", L"5" },
        { L"SIX", L"6" }, { L"SEVEN", L"7" }, { L"EIGHT", L"8" }, { L"NINE", L"9" }, { L"PAGE_UP", L"Page Up" },
        { L"PAGE_DOWN", L"Page Down" }, { L"LEFT_ARROW", L"Left" }, { L"RIGHT_ARROW", L"Right" }, { L"UP_ARROW", L"Up" },
        { L"DOWN_ARROW", L"Down" }, { L"RETURN", L"Enter" }, { L"BACKSPACE", L"Backspace" }, { L"SPACE", L"Space" },
    };
    for (auto& n : nice) if (k == n.a) return n.b;
    if (k.rfind(L"NUM_", 0) == 0) return L"Num " + key_label(k.substr(4));
    return k;
}
// keys the game itself uses (warned about, still allowed)
static bool game_key(const std::wstring& k) {
    static const wchar_t* used[] = { L"W", L"A", L"S", L"D", L"E", L"C", L"SPACE", L"TAB", L"F", L"R", L"Q" };
    for (auto u : used) if (k == u) return true;
    return false;
}

static void set_key(UINT vk) {
    Chapter& c = cur();
    if (g_capture < 0 || g_capture >= (int)c.keys.size()) return;
    if (vk == VK_ESCAPE) { g_capture = -1; return; }
    const wchar_t* n = vk_name(vk);
    if (!n) { toast(tr(L"That key can't be used - pick another one.")); return; }
    std::wstring k = n;
    if (k == L"F8" || k == L"F9") toast(tr(L"F8 / F9 are kept free for other mods - pick another key."));
    else if (k == L"F10") toast(tr(L"F10 opens the game console - pick another key."));
    else {
        for (int i = 0; i < (int)c.keys.size(); i++)
            if (i != g_capture && c.keys[i].value == k) { c.keys[i].value = c.keys[g_capture].value; toast(tr(L"Swapped with \"") + std::wstring(c.keys[i].label) + L"\"."); }
        c.keys[g_capture].value = k;
        if (game_key(k)) toast(tr(L"Careful: the game uses ") + key_label(k) + tr(L" too."));
        apply_keys_everywhere(c);
    }
    g_capture = -1;
}

static void draw_toggle(int x, int y, bool on) {
    double t = anim(akey(2, x, y), on ? 1.0 : 0.0, 18);
    RECT r = R(x, y, 40, 22);
    fill(r, mix(C_LINE, accent(), t), 11);
    circle(x + 11 + (int)(18 * t + 0.5), y + 11, 8, RGB(255, 255, 255));
}

static void draw_settings(int h) {
    Chapter& c = cur();
    button(MX, 26, 96, 32, tr(L"\x2039  Back"), Btn::Ghost, [] { g_page = Page::Chapter; g_capture = -1; g_confirm_uninstall = false; });
    text(R(MX + 112, 28, MW - 112, 30), tr(L"Chapter ") + std::to_wstring(c.num) + tr(L" settings"), F_BIG, C_TEXT, DT_LEFT | DT_VCENTER | DT_SINGLELINE);
    if (g_running[g_sel]) text(R(MX, 64, MW, 18), tr(L"The game is running - changes apply next time you start it."), F_SMALL, C_WARN, DT_LEFT | DT_SINGLELINE);

    // keys
    int y = 92;
    const int KW = std::max(300, std::min(370, MW - 470));   // left column: 300 wide, more in a bigger window
    const int BW = (KW - 44) / 2;                            // half-width button in it
    RECT kc = R(MX, y, KW, 254);
    fill(kc, C_CARD, 14);
    text(R(MX + 18, y + 14, KW - 40, 18), tr(L"KEYS"), F_SMALL, acc_text(), DT_LEFT | DT_SINGLELINE);
    const size_t nk = c.keys.size();               // up to 6 keys fit the card
    const int kstep = nk > 6 ? 25 : nk > 5 ? 29 : nk > 4 ? 35 : 44, kh = nk > 6 ? 23 : nk > 5 ? 26 : nk > 4 ? 30 : 34;
    for (int i = 0; i < (int)c.keys.size(); i++) {
        int ry = y + 40 + i * kstep;
        text(R(MX + 18, ry, KW - 130, kh), tr(c.keys[i].label), F_SMALL, C_TEXT, DT_LEFT | DT_VCENTER | DT_SINGLELINE);
        bool cap = g_capture == i;
        std::wstring lbl = cap ? L"press a key" : key_label(c.keys[i].value);
        button(MX + KW - 110, ry, 92, kh, lbl, cap ? Btn::Primary : Btn::Secondary, [i] { g_capture = g_capture == i ? -1 : i; g_focus = {}; });
    }
    button(MX + 18, y + 218, 150, 26, tr(L"Reset keys"), Btn::Ghost, [] {
        Chapter& ch = cur();
        for (auto& k : ch.keys) k.value = k.def;
        apply_keys_everywhere(ch); toast(tr(L"Keys reset to the defaults."));
    });
    text(R(MX + 176, y + 214, KW - 180, 34), tr(L"Click a key, then press the new one"), F_SMALL, C_DIM);

    // sync options
    const int SX = MX + KW + 12, SW = MW - KW - 12;
    int nrows0 = 0;
    for (auto& o : c.sync) if (o.chapters & (1 << (c.num - 1))) nrows0++;
    // row height from the room the window has (bigger window = more air), 29..46
    const int step = std::max(29, std::min(46, nrows0 ? (h - 44 - y - 74) / nrows0 : 46));
    const int card_h = std::max(446, 40 + nrows0 * step + 34);
    RECT sc = R(SX, y, SW, card_h);
    fill(sc, C_CARD, 14);
    text(R(SX + 18, y + 14, SW - 36, 18), tr(L"SHARED WITH YOUR ROOM"), F_SMALL, acc_text(), DT_LEFT | DT_SINGLELINE);
    int row = 0;
    const int hint_dy = step < 30 ? 14 : step < 34 ? 15 : 17;
    for (int i = 0; i < (int)c.sync.size(); i++) {
        SyncOpt& o = c.sync[i];
        if (!(o.chapters & (1 << (c.num - 1)))) continue;
        int ry = y + 40 + row * step;
        RECT rr = R(SX + 8, ry - 3, SW - 16, step - 2);
        if (hover(rr)) fill(rr, C_CARD2, 8);
        text(R(SX + 18, ry, SW - 90, 18), tr(o.label), F_SMALL, C_TEXT, DT_LEFT | DT_SINGLELINE | DT_END_ELLIPSIS);
        text(R(SX + 18, ry + hint_dy, SW - 90, 16), tr(o.hint), F_SMALL, C_DIM, DT_LEFT | DT_SINGLELINE | DT_END_ELLIPSIS);
        draw_toggle(SX + SW - 58, ry + (step < 34 ? 5 : 8), o.value);
        click(rr, [i] { Chapter& ch = cur(); ch.sync[i].value = !ch.sync[i].value; speedrun_preset(ch, i); apply_settings(ch); });
        row++;
    }
    text(R(SX + 18, y + card_h - 26, SW - 36, 20), tr(L"Use the same settings as your friends."), F_SMALL, C_DIM, DT_LEFT | DT_SINGLELINE);

    // folder + mod
    int my = y + 266;
    RECT mc = R(MX, my, KW, 214);
    fill(mc, C_CARD, 14);
    text(R(MX + 18, my + 14, KW - 40, 18), tr(L"CO-OP MOD"), F_SMALL, acc_text(), DT_LEFT | DT_SINGLELINE);
    std::wstring iv = inst_ver(c);
    text(R(MX + 18, my + 34, KW - 30, 18), iv.empty() ? tr(L"Not installed") : L"v" + iv + (iv == MOD_VERSION ? tr(L" installed") : tr(L" (update ready)")), F_SMALL, iv.empty() ? C_WARN : C_TEXT, DT_LEFT | DT_SINGLELINE);
    text(R(MX + 18, my + 54, KW - 34, 18), c.dir, F_SMALL, C_DIM, DT_LEFT | DT_SINGLELINE | DT_PATH_ELLIPSIS);
    my += 30;
    int idx = g_sel;
    button(MX + 18, my + 60, BW, 30, tr(L"Reinstall"), Btn::Secondary, [idx] {
        if (game_running(g_ch[idx])) { toast(tr(L"Close the game first.")); return; }
        start_install(idx, false);
    }, !g_installing);
    button(MX + 26 + BW, my + 60, BW, 30, g_confirm_uninstall ? tr(L"Click to confirm") : tr(L"Uninstall"), g_confirm_uninstall ? Btn::Danger : Btn::Ghost, [idx] {
        Chapter& ch = g_ch[idx];
        if (!g_confirm_uninstall) { g_confirm_uninstall = true; return; }
        g_confirm_uninstall = false;
        if (game_running(ch)) { toast(tr(L"Close the game first.")); return; }
        bool ok = (DeleteFileW((bin_dir(ch) + L"\\dwmapi.dll").c_str()) || !file_exists(bin_dir(ch) + L"\\dwmapi.dll"));
        ok = delete_tree(mod_dir(ch)) && ok;
        iv_reset();
        toast(ok ? tr(L"Co-op mod removed - your game is back to normal.") : tr(L"Couldn't remove everything - close the game or run the launcher as administrator."));
    }, !iv.empty() && !g_installing);
    button(MX + 18, my + 98, BW, 30, tr(L"Change folder"), Btn::Ghost, [idx] { browse_folder(g_ch[idx]); });
    button(MX + 26 + BW, my + 98, BW, 30, tr(L"Open folder"), Btn::Ghost, [idx] {
        Chapter& ch = g_ch[idx];
        std::wstring d = dir_exists(mod_dir(ch)) ? mod_dir(ch) : ch.dir;
        ShellExecuteW(nullptr, L"open", d.c_str(), nullptr, nullptr, SW_SHOWNORMAL);
    });
    // after a crash: the Logs page lists the last sessions and crash reports (copy for Discord / report zip)
    button(MX + 18, my + 136, KW - 36, 30, tr(L"Logs & crashes"), Btn::Ghost, [] { open_logs(); });
}

// ------------------------------------------------------------------ logs page (last sessions + crash reports of a chapter)
static void open_logs() {
    g_logs = scan_logs(cur(), g_running[g_sel]);
    log_select(0);
    g_page = Page::Logs; g_focus = {}; g_capture = -1; g_confirm_uninstall = false;
}

static std::wstring log_title(const LogEntry& e) {
    if (e.running) return tr(L"Running now");
    std::wstring t = ft_local_string(e.start ? e.start : e.end, L"");
    if (e.path.empty()) return t + L"  -  " + tr(L"game crashed");
    return t;
}
static std::wstring log_sub(const LogEntry& e) {
    std::wstring s;
    if (e.path.empty()) return tr(L"Crash report only - the session's log was overwritten");
    if (e.start && e.end > e.start) {
        ULONGLONG mins = (e.end - e.start) / (60 * FT_SECOND);
        s = mins < 1 ? tr(L"under 1 min") : std::to_wstring(mins) + L" min";
    }
    if (!e.version.empty()) s += (s.empty() ? L"" : L"  -  ") + std::wstring(L"v") + e.version;
    if (e.errors) s += L"  -  " + std::to_wstring(e.errors) + tr(L" errors");
    return s;
}

static void draw_logs(int h) {
    Chapter& c = cur();
    button(MX, 26, 96, 32, tr(L"\x2039  Back"), Btn::Ghost, [] { g_page = Page::Chapter; });
    text(R(MX + 112, 28, MW - 250, 30), tr(L"Chapter ") + std::to_wstring(c.num) + tr(L" logs"), F_BIG, C_TEXT, DT_LEFT | DT_VCENTER | DT_SINGLELINE);
    button(MX + MW - 130, 26, 130, 32, tr(L"Refresh"), Btn::Ghost, [] { int s = g_log_sel; open_logs(); g_log_sel = std::min(s, std::max(0, (int)g_logs.size() - 1)); });
    text(R(MX, 66, MW, 20), tr(L"Your last game sessions. Crashed ones are red - send us the report zip or copy the log into Discord."), F_SMALL, C_DIM, DT_LEFT | DT_SINGLELINE | DT_END_ELLIPSIS);
    if (g_logs.empty()) {
        RECT card = R(MX, 100, MW, 90);
        fill(card, C_CARD, 14);
        text(R(MX + 24, 122, MW - 48, 50), tr(L"No logs yet - they show up here after you played this chapter once."), F_BODY, C_DIM);
        return;
    }
    // list (left) + preview of the selected entry (right)
    const int LW = std::max(260, std::min(330, MW * 2 / 5)), RH = 52, top = 98;
    const int fit = std::max(1, (h - top - 30) / (RH + 6));
    int first = std::max(0, std::min(g_log_sel - fit + 1, (int)g_logs.size() - fit));
    first = std::max(0, std::min(first, g_log_sel));
    for (int i = first; i < (int)g_logs.size() && i < first + fit; i++) {
        const LogEntry& e = g_logs[i];
        int y = top + (i - first) * (RH + 6);
        RECT r = R(MX, y, LW, RH);
        bool sel = i == g_log_sel;
        fill(r, sel ? mix(C_CARD, accent(), 0.18) : hover(r) ? C_CARD2 : C_CARD, 10);
        if (sel) frame(r, accent(), 10, 2);
        COLORREF dot = e.running ? C_OK : !e.crash_dir.empty() ? C_BAD : e.errors ? C_WARN : mix(C_DIM, C_CARD, 0.3);
        circle(MX + 18, y + RH / 2, 5, dot);
        text(R(MX + 32, y + 7, LW - 44, 20), log_title(e), F_BOLD, C_TEXT, DT_LEFT | DT_SINGLELINE | DT_END_ELLIPSIS);
        std::wstring sub = !e.crash_dir.empty() && !e.path.empty() ? tr(L"Crashed") + L"  -  " + log_sub(e) : log_sub(e);
        text(R(MX + 32, y + 28, LW - 44, 18), sub, F_SMALL, !e.crash_dir.empty() ? C_BAD : C_DIM, DT_LEFT | DT_SINGLELINE | DT_END_ELLIPSIS);
        click(r, [i] { log_select(i); });
    }
    if ((int)g_logs.size() > fit) {
        int y = top + fit * (RH + 6) - 2;
        text(R(MX, y, LW, 18), std::to_wstring(g_log_sel + 1) + L" / " + std::to_wstring(g_logs.size()) + tr(L"  -  arrow keys / click"), F_SMALL, C_DIM, DT_CENTER | DT_SINGLELINE);
    }

    if (g_log_sel >= (int)g_logs.size()) g_log_sel = 0;
    const LogEntry& e = g_logs[g_log_sel];
    const int PX = MX + LW + 12, PW = MW - LW - 12, PH = h - top - 30;
    RECT pc = R(PX, top, PW, PH);
    fill(pc, C_CARD, 14);
    int y = top + 14;
    text(R(PX + 18, y, PW - 36, 18), e.running ? tr(L"LIVE LOG") : !e.crash_dir.empty() ? tr(L"CRASH") : tr(L"GAME LOG"), F_SMALL, !e.crash_dir.empty() ? C_BAD : acc_text(), DT_LEFT | DT_SINGLELINE);
    y += 24;
    const int LH = 17, bottom = top + PH - 96;
    if (!e.crash_msg.empty()) {
        size_t p = 0;
        for (int n = 0; p < e.crash_msg.size() && n < 6 && y < bottom; n++) {
            size_t q = e.crash_msg.find('\n', p);
            std::string l = e.crash_msg.substr(p, q == std::string::npos ? std::string::npos : q - p);
            if (!l.empty()) { text(R(PX + 18, y, PW - 36, LH), wide(l), n == 0 ? F_BOLD : F_SMALL, n == 0 ? C_BAD : C_TEXT, DT_LEFT | DT_SINGLELINE | DT_END_ELLIPSIS); y += LH + (n == 0 ? 3 : 0); }
            if (q == std::string::npos) break;
            p = q + 1;
        }
        y += 8;
    }
    // log lines, as many as fit; the wheel / Page Up / Page Down scroll (g_log_scroll lines up from the end)
    int room = std::max(1, (bottom - y) / LH);
    g_log_page = room;
    g_log_view = R(PX, y, PW, room * LH);
    int total = (int)e.tail.size();
    g_log_scroll = std::max(0, std::min(g_log_scroll, std::max(0, total - room)));
    int last = total - g_log_scroll, firstl = std::max(0, last - room);
    g_log_total = total;
    g_log_track = {};
    if (total > room) {                            // scroll bar: drag the thumb or click the bar to jump
        int th = room * LH, bh = std::max(24, th * room / total);
        int bt = (th - bh) * firstl / std::max(1, total - room);
        g_log_track = R(PX + PW - 22, y, 20, th);
        RECT tr_px = R(PX + PW - 22, y, 20, th);
        g_log_thumb_top = tr_px.top + (int)((tr_px.bottom - tr_px.top) * (long long)bt / std::max(1, th));
        g_log_thumb_h = (int)((tr_px.bottom - tr_px.top) * (long long)bh / std::max(1, th));
        bool hot = g_log_drag || hover(g_log_track);
        fill(R(PX + PW - 14, y, 6, th), mix(C_CARD, C_LINE, hot ? 0.9 : 0.6), 3);
        fill(R(PX + PW - 14, y + bt, 6, bh), g_log_drag ? accent() : mix(C_DIM, C_TEXT, hot ? 0.5 : 0.0), 3);
    }
    for (size_t k = (size_t)firstl; k < (size_t)last; k++) {
        const std::string& l = e.tail[k];
        bool err = l.find("Error") != std::string::npos || l.find("traceback") != std::string::npos;
        text(R(PX + 18, y, PW - 46, LH), wide(l), F_SMALL, err ? C_WARN : C_DIM, DT_LEFT | DT_SINGLELINE | DT_END_ELLIPSIS | DT_NOPREFIX);
        y += LH;
    }
    // actions
    int by = top + PH - 84, bw = (PW - 36 - 10) / 2;
    int idx = g_sel;
    LogEntry ent = e;
    button(PX + 18, by, bw, 32, tr(L"Copy for Discord"), Btn::Secondary, [idx, ent] {
        copy_text(log_report_text(g_ch[idx], ent));
        toast(tr(L"Copied - paste it in Discord (Ctrl+V)."));
    });
    button(PX + 28 + bw, by, bw, 32, tr(L"Report zip"), Btn::Primary, [idx, ent] {
        std::wstring log = ent.path.empty() ? bin_dir(g_ch[idx]) + L"\\ue4ss\\UE4SS.log" : ent.path;
        std::wstring zip = make_report_zip(g_ch[idx], log, ent.crash_dir);
        if (zip.empty()) { toast(tr(L"Couldn't make the zip - use Copy for Discord or Open folder.")); return; }
        ShellExecuteW(nullptr, L"open", L"explorer.exe", (L"/select,\"" + zip + L"\"").c_str(), nullptr, SW_SHOWNORMAL);
        toast(running_on_wine() ? tr(L"PoppyCoop_report.zip is in the launcher folder - send it to us.") : tr(L"PoppyCoop_report.zip is on your desktop - send it to us."));
    });
    button(PX + 18, by + 40, bw, 32, tr(L"Open log"), Btn::Ghost, [ent] {
        if (ent.path.empty()) { toast(tr(L"This crash has no log any more.")); return; }
        ShellExecuteW(nullptr, L"open", L"notepad.exe", (L"\"" + ent.path + L"\"").c_str(), nullptr, SW_SHOWNORMAL);
    }, !e.path.empty());
    button(PX + 28 + bw, by + 40, bw, 32, tr(L"Open folder"), Btn::Ghost, [ent] {
        std::wstring f = ent.path.empty() ? ent.crash_dir : ent.path;
        ShellExecuteW(nullptr, L"open", L"explorer.exe", (L"/select,\"" + f + L"\"").c_str(), nullptr, SW_SHOWNORMAL);
    });
}

// ------------------------------------------------------------------ what's new page
// Every update with its changes (release/notes, built in by tools/gen_news.py): the list on the left, the selected
// update's changes on the right - like the Logs page. Wheel / arrow keys pick an update, the wheel over the
// changes scrolls them.
#include "build/news_data.h"
static const int NEWS_N = (int)(sizeof(RELEASES) / sizeof(RELEASES[0]));
static int g_news_sel = 0, g_news_scroll = 0, g_news_max = 0;
static RECT g_news_view = {};
static void news_select(int i) { g_news_sel = std::max(0, std::min(NEWS_N - 1, i)); g_news_scroll = 0; }
static int text_h(const std::wstring& s, HFONT f, int w) {          // height (layout units) of wrapped text
    SelectObject(g_dc, f);
    RECT rr = { 0, 0, S(w), 0 };
    DrawTextW(g_dc, s.c_str(), (int)s.size(), &rr, DT_LEFT | DT_WORDBREAK | DT_CALCRECT | DT_NOPREFIX);
    return (int)((rr.bottom - rr.top) / g_s + 0.999);
}
static void draw_news(int h) {
    button(MX, 26, 96, 32, tr(L"\x2039  Back"), Btn::Ghost, [] { g_page = g_news_back; });
    text(R(MX + 112, 22, MW - 112, 18), tr(L"WHAT'S NEW"), F_SMALL, acc_text(), DT_LEFT | DT_SINGLELINE);
    text(R(MX + 112, 38, MW - 360, 30), L"PoppyCoop v" MOD_VERSION, F_BIG, C_TEXT, DT_LEFT | DT_SINGLELINE);
    button(MX + MW - 230, 30, 230, 32, tr(L"All releases on GitHub"), Btn::Ghost, [] { ShellExecuteW(nullptr, L"open", RELEASES_PAGE, nullptr, nullptr, SW_SHOWNORMAL); });
    if (NEWS_N == 0) return;
    if (g_news_sel >= NEWS_N) g_news_sel = 0;
    const int LW = std::max(240, std::min(300, MW * 2 / 5)), RH = 52, top = 84;
    const int fit = std::max(1, (h - top - 30) / (RH + 6));
    int first = std::max(0, std::min(g_news_sel - fit + 1, NEWS_N - fit));
    first = std::max(0, std::min(first, g_news_sel));
    for (int i = first; i < NEWS_N && i < first + fit; i++) {
        const ReleaseNotes& rn = RELEASES[i];
        int y = top + (i - first) * (RH + 6);
        RECT r = R(MX, y, LW, RH);
        bool sel = i == g_news_sel, mine = std::wstring(rn.ver) == MOD_VERSION;
        fill(r, sel ? mix(C_CARD, accent(), 0.18) : hover(r) ? C_CARD2 : C_CARD, 10);
        if (sel) frame(r, accent(), 10, 2);
        circle(MX + 18, y + RH / 2, 5, i == 0 ? accent() : mix(C_DIM, C_CARD, 0.3));
        text(R(MX + 32, y + 7, LW - 44, 20), L"v" + std::wstring(rn.ver) + (mine ? tr(L"  -  installed") : L""), F_BOLD, C_TEXT, DT_LEFT | DT_SINGLELINE | DT_END_ELLIPSIS);
        text(R(MX + 32, y + 28, LW - 44, 18), g_lang == 1 ? rn.summary_de : rn.summary, F_SMALL, C_DIM, DT_LEFT | DT_SINGLELINE | DT_END_ELLIPSIS);
        click(r, [i] { news_select(i); });
    }
    if (NEWS_N > fit) {
        int y = top + fit * (RH + 6) - 2;
        text(R(MX, y, LW, 18), std::to_wstring(g_news_sel + 1) + L" / " + std::to_wstring(NEWS_N) + tr(L"  -  arrow keys / click"), F_SMALL, C_DIM, DT_CENTER | DT_SINGLELINE);
    }
    // the selected update's changes (one bullet per line of its notes), scrollable
    const ReleaseNotes& rn = RELEASES[g_news_sel];
    const int PX = MX + LW + 12, PW = MW - LW - 12, PH = h - top - 30;
    fill(R(PX, top, PW, PH), C_CARD, 14);
    text(R(PX + 18, top + 14, PW - 36, 18), tr(L"UPDATE"), F_SMALL, acc_text(), DT_LEFT | DT_SINGLELINE);
    text(R(PX + 18, top + 32, PW - 36, 28), L"v" + std::wstring(rn.ver), F_BIG, C_TEXT, DT_LEFT | DT_SINGLELINE);
    const int vy = top + 72, vh = PH - 72 - 14, tw = PW - 36 - 22;
    g_news_view = R(PX, vy, PW, vh);
    std::vector<std::wstring> items;
    for (const wchar_t* p = g_lang == 1 ? rn.items_de : rn.items; *p; ) {
        const wchar_t* q = wcschr(p, L'\n');
        items.emplace_back(p, q ? q - p : wcslen(p));
        if (!q) break;
        p = q + 1;
    }
    int total = 0;
    std::vector<int> hs;
    for (auto& it : items) { int hh = text_h(it, F_BODY, tw); hs.push_back(hh); total += hh + 12; }
    g_news_max = std::max(0, total - vh);
    g_news_scroll = std::max(0, std::min(g_news_scroll, g_news_max));
    int saved = SaveDC(g_dc);
    RECT clip = g_news_view;
    IntersectClipRect(g_dc, clip.left, clip.top, clip.right, clip.bottom);
    int y = vy - g_news_scroll;
    for (size_t k = 0; k < items.size(); k++) {
        if (y + hs[k] >= vy && y <= vy + vh) {
            circle(PX + 24, y + 10, 3, accent());
            text(R(PX + 36, y, tw, hs[k] + 4), items[k], F_BODY, C_TEXT, DT_LEFT | DT_TOP | DT_WORDBREAK);
        }
        y += hs[k] + 12;
    }
    RestoreDC(g_dc, saved);
    if (g_news_max > 0) {                          // scroll position
        int th = vh, bh = std::max(24, th * vh / std::max(1, total));
        int bt = (th - bh) * g_news_scroll / std::max(1, g_news_max);
        fill(R(PX + PW - 14, vy, 6, th), mix(C_CARD, C_LINE, 0.6), 3);
        fill(R(PX + PW - 14, vy + bt, 6, bh), mix(C_DIM, C_TEXT, 0.2), 3);
    }
}

// ------------------------------------------------------------------ profile page
static void draw_profile(int h) {
    button(MX, 26, 96, 32, tr(L"\x2039  Back"), Btn::Ghost, [] {
        std::wstring n = clean_name(g_edit_name);
        if (!n.empty()) g_prof.name = n;
        save_profile(); g_page = Page::Chapter; g_focus = {};
    });
    text(R(MX + 112, 28, MW - 112, 30), tr(L"Name & colour"), F_BIG, C_TEXT, DT_LEFT | DT_VCENTER | DT_SINGLELINE);
    RECT card = R(MX, 84, MW, 250);
    fill(card, C_CARD, 14);
    text(R(MX + 24, 104, 400, 18), tr(L"PLAYER NAME"), F_SMALL, acc_text(), DT_LEFT | DT_SINGLELINE);
    textbox(MX + 24, 126, 320, 44, &g_edit_name, 24, false, L"Your name", F_BIG);
    text(R(MX + 24, 176, MW - 210, 34), tr(L"Your name floats above your figure in everyone else's game. Letters, numbers, _ and - only."), F_SMALL, C_DIM);
    text(R(MX + 24, 214, 400, 18), tr(L"FIGURE COLOUR"), F_SMALL, acc_text(), DT_LEFT | DT_SINGLELINE);
    draw_colors(MX + 24, 238);
    for (auto& c : COLORS) if (g_prof.color == c.id) text(R(MX + 24, 284, 300, 20), std::wstring(c.label) + tr(L" - your figure's colour in other players' games"), F_SMALL, C_DIM, DT_LEFT | DT_SINGLELINE);
    {   // preview: the figure as your friends see it (mannequin with round head, name tag above)
        int px = MX + MW - 90;
        COLORREF fc = player_rgb(g_prof.color);
        std::wstring nm = clean_name(g_edit_name);
        text(R(px - 90, 96, 180, 20), nm.empty() ? g_prof.name : nm, F_SMALL, RGB(255, 214, 40), DT_CENTER | DT_SINGLELINE);
        circle(px, 136, 17, fc);
        fill(R(px - 4, 151, 8, 8), fc, 2);
        fill(R(px - 20, 158, 40, 66), fc, 8);
        fill(R(px - 33, 162, 11, 52), fc, 5);
        fill(R(px + 22, 162, 11, 52), fc, 5);
        fill(R(px - 17, 226, 14, 62), fc, 5);
        fill(R(px + 3, 226, 14, 62), fc, 5);
        circle(px - 27, 220, 7, RGB(70, 110, 230));     // blue hand
        circle(px + 27, 220, 7, RGB(220, 50, 40));      // red hand
    }
    button(MX + MW - 160, 346, 160, 42, tr(L"Done"), Btn::Primary, [] {
        std::wstring n = clean_name(g_edit_name);
        if (n.empty()) { toast(tr(L"Type a name first.")); return; }
        g_prof.name = n; save_profile(); g_page = Page::Chapter; g_focus = {};
        for (auto& ch : g_ch) if (!inst_ver(ch).empty()) write_mod_settings(ch, g_prof);
    });
    (void)h;
}

// Download the newest release and swap the exe (WM_APP_SELFUPD restarts the launcher when it worked).
static void start_self_update() {
    if (g_updating || (g_latest_zip.empty() && g_latest_exe.empty())) return;
    g_updating = true;
    toast(tr(L"Updating to v") + g_latest + L"...");
    std::wstring url = g_latest_zip, exe_url = g_latest_exe;
    std::thread([w = g_wnd, url, exe_url] {
        std::wstring* r = new std::wstring(self_update(url, exe_url));
        if (!PostMessageW(w, WM_APP_SELFUPD, 0, (LPARAM)r)) delete r;
    }).detach();
}
// "Automatic updates": a newer release found at start is installed right away - unless a game is running, or
// this very version was already tried once (a broken download must not restart the launcher in a loop)
static void maybe_auto_update() {
    if (!g_autoupd || g_updating || g_latest.empty() || (g_latest_zip.empty() && g_latest_exe.empty()) || !version_newer(g_latest, MOD_VERSION)) return;
    for (size_t i = 0; i < g_ch.size() && i < 8; i++) if (g_running[i]) return;
    if (ini_get(L"Launcher", L"AutoUpdateTried") == g_latest) return;
    ini_set(L"Launcher", L"AutoUpdateTried", g_latest);
    start_self_update();
}

// ------------------------------------------------------------------ launcher settings page (colours, animations)
static void save_app_prefs() {
    ini_set(L"Launcher", L"Theme", g_theme);
    ini_set(L"Launcher", L"Accent", g_accent_pref);
    ini_set(L"Launcher", L"Animations", g_anims ? L"1" : L"0");
    ini_set(L"Launcher", L"Lang", g_lang == 1 ? L"de" : L"en");
    ini_set(L"Launcher", L"Experimental", g_experimental ? L"1" : L"0");
    ini_set(L"Launcher", L"Multi", g_multi ? L"1" : L"0");
    ini_set(L"Launcher", L"SplitLayout", std::to_wstring(g_split_layout));
    g_split_on = g_multi && g_split_layout > 0;
    ini_set(L"Launcher", L"CoopAlways", g_coop_always ? L"1" : L"0");
    ini_set(L"Launcher", L"AutoUpdate", g_autoupd ? L"1" : L"0");
    if (g_crashrep >= 0) ini_set(L"Launcher", L"CrashReports", g_crashrep ? L"1" : L"0");
}
static void set_experimental(bool on) {
    g_experimental = on;
    save_app_prefs();
    for (auto& c : g_ch) if (c.experimental) { chapter_load(c); }
    if (!on && cur().experimental) { g_sel = 0; g_page = Page::Chapter; }
    if (on) toast(tr(L"Experimental chapters are on - pick Chapter 3, 4 or 5 on the left."));
}

static void draw_app(int h) {
    text(R(MX, 28, MW, 18), tr(L"LAUNCHER"), F_SMALL, acc_text(), DT_LEFT | DT_SINGLELINE);
    text(R(MX, 46, MW, 40), tr(L"Launcher settings"), F_H1, C_TEXT, DT_LEFT | DT_SINGLELINE);
    text(R(MX, 92, MW, 20), tr(L"How the launcher looks, plus a few extras."), F_BODY, C_DIM, DT_LEFT | DT_SINGLELINE);
    // language (top right)
    button(MX + MW - 230, 46, 110, 32, L"English", g_lang == 0 ? Btn::Primary : Btn::Ghost, [] { g_lang = 0; save_app_prefs(); });
    button(MX + MW - 110, 46, 110, 32, L"Deutsch", g_lang == 1 ? Btn::Primary : Btn::Ghost, [] { g_lang = 1; save_app_prefs(); });

    // themes: a small preview of each
    text(R(MX, 130, MW, 18), tr(L"THEME"), F_SMALL, acc_text(), DT_LEFT | DT_SINGLELINE);
    int cw = (MW - 32) / 3;
    for (int i = 0; i < 3; i++) {
        const Theme& t = THEMES[i];
        int x = MX + i * (cw + 16);
        RECT r = R(x, 152, cw, 132);
        bool sel = g_theme == t.id;
        double ht = anim(akey(20, i, 0), hover(r) ? 1.0 : 0.0, 16), st = anim(akey(21, i, 0), sel ? 1.0 : 0.0, 14);
        fill(r, mix(C_CARD, C_CARD2, ht), 12);
        fill(R(x + 12, 164, cw - 24, 80), t.bg, 8);                        // mini window
        fill(R(x + 12, 164, 46, 80), t.side, 8);
        fill(R(x + 20, 176, 30, 6), t.text, 3);
        fill(R(x + 20, 190, 24, 5), t.dim, 2);
        fill(R(x + 66, 176, cw - 92, 26), t.card, 6);
        fill(R(x + 74, 184, 50, 6), t.text, 3);
        fill(R(x + cw - 74, 222, 50, 14), target_accent(), 7);
        text(R(x + 14, 252, cw - 28, 22), t.label, F_BOLD, C_TEXT, DT_LEFT | DT_VCENTER | DT_SINGLELINE);
        if (st > 0.02) { frame(r, mix(C_CARD, accent(), st), 12, 2); circle(x + cw - 22, 263, 7, mix(C_CARD, accent(), st)); }
        std::wstring id = t.id;
        click(r, [id] { g_theme = id; apply_theme(); save_app_prefs(); });
    }

    // accent colour
    text(R(MX, 306, MW, 18), tr(L"ACCENT COLOUR"), F_SMALL, acc_text(), DT_LEFT | DT_SINGLELINE);
    {
        RECT r = R(MX, 328, 196, 40);
        bool sel = g_accent_pref == L"figure";
        double ht = anim(akey(22, 0, 0), hover(r) ? 1.0 : 0.0, 16), st = anim(akey(23, 0, 0), sel ? 1.0 : 0.0, 14);
        fill(r, mix(C_CARD, C_CARD2, ht), 20);
        if (st > 0.02) frame(r, mix(C_CARD, accent(), st), 20, 2);
        circle(MX + 22, 348, 9, player_rgb(g_prof.color));
        text(R(MX + 40, 328, 150, 40), tr(L"My figure colour"), F_SMALL, C_TEXT, DT_LEFT | DT_VCENTER | DT_SINGLELINE);
        click(r, [] { g_accent_pref = L"figure"; save_app_prefs(); });
    }
    for (int i = 0; i < 7; i++) {
        int cx = MX + 232 + i * 46;
        RECT r = R(cx - 18, 330, 36, 36);
        bool sel = g_accent_pref == COLORS[i].id;
        double st = anim(akey(24, i, 0), sel ? 1.0 : 0.0, 16), ht = anim(akey(25, i, 0), hover(r) ? 1.0 : 0.0, 16);
        if (st > 0.02) { circle(cx, 348, 12 + (int)(6 * st + 0.5), mix(C_BG, C_TEXT, st)); circle(cx, 348, 12 + (int)(3 * st + 0.5), C_BG); }
        else if (ht > 0.02) circle(cx, 348, 12 + (int)(5 * ht + 0.5), mix(C_BG, C_LINE, ht));
        circle(cx, 348, 12, COLORS[i].rgb);
        std::wstring id = COLORS[i].id;
        click(r, [id] { g_accent_pref = id; save_app_prefs(); });
    }
    text(R(MX, 376, MW, 20), tr(L"\"My figure colour\" follows the colour you play with (Name & colour)."), F_SMALL, C_DIM, DT_LEFT | DT_SINGLELINE);

    // animations
    auto row = [](int y, int k, const wchar_t* title, const wchar_t* hint, bool on, std::function<void()> fn) {
        RECT ar = R(MX, y, MW, 48);
        fill(ar, mix(C_CARD, C_CARD2, anim(akey(26, k, 0), hover(ar) ? 1.0 : 0.0, 16)), 12);
        text(R(MX + 18, y + 5, MW - 100, 20), tr(title), F_BOLD, C_TEXT, DT_LEFT | DT_SINGLELINE);
        text(R(MX + 18, y + 25, MW - 100, 18), tr(hint), F_SMALL, C_DIM, DT_LEFT | DT_SINGLELINE | DT_END_ELLIPSIS);
        draw_toggle(MX + MW - 60, y + 13, on);
        click(ar, fn);
    };
    row(410, 0, L"Animations", L"Smooth fades and movements. Turn off on very slow PCs.", g_anims, [] { g_anims = !g_anims; save_app_prefs(); });
    row(462, 1, L"Experimental chapters", L"Try Chapters 3-5: you see each other, but doors, puzzles and items aren't shared.", g_experimental, [] { set_experimental(!g_experimental); });
    row(514, 2, L"Several games at once", g_multi ? L"Split screen: PLAY starts more game windows." : L"For Nucleus Co-op / split screen: PLAY can start more game windows.", g_multi, [] { g_multi = !g_multi; save_app_prefs(); });
    if (g_multi)       // split screen layout: click cycles (drawn over the row, so it gets the click first)
        button(MX + MW - 330, 514 + 9, 250, 30, tr(L"Layout: ") + tr(split_layout_name(g_split_layout)), Btn::Secondary, [] {
            g_split_layout = (g_split_layout + 1) % SPLIT_LAYOUTS; save_app_prefs();
            toast(g_split_layout ? tr(L"Next start: the game windows are placed ") + tr(split_layout_name(g_split_layout)) : tr(L"Game windows are not arranged."));
        });
    row(618, 5, L"Co-op without the launcher", L"Also when the game is started from Steam (e.g. Steam Deck game mode). Off: only via PLAY here.", g_coop_always, [] {
        g_coop_always = !g_coop_always; save_app_prefs();
        for (auto& ch : g_ch) if (!inst_ver(ch).empty()) write_launch_mark(ch);   // "always" / back to a stale time
        if (!g_coop_always) for (auto& ch : g_ch) if (!inst_ver(ch).empty() && !game_running(ch)) {
            HANDLE f = CreateFileW((mod_dir(ch) + L"\\launch.txt").c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, 0, nullptr);
            if (f != INVALID_HANDLE_VALUE) { DWORD w; WriteFile(f, "0\n", 2, &w, nullptr); CloseHandle(f); }
        }
    });
    if (FEATURE_ONLINE) row(670, 4, L"Send crash reports", L"After a crash, send the error and the mod log to the developers (no user names).", g_crashrep == 1, [] { g_crashrep = g_crashrep == 1 ? 0 : 1; save_app_prefs(); if (g_crashrep == 1) maybe_report_crashes(); });
    row(566, 3, L"Automatic updates", L"Install a new version by itself when the launcher starts.", g_autoupd, [] { g_autoupd = !g_autoupd; save_app_prefs(); if (g_autoupd) maybe_auto_update(); });
    (void)h;
}

// ------------------------------------------------------------------ servers page
static void select_server(int i) {
    g_srv = i;
    apply_server();
    save_servers();
    if (!trim(g_prof.name).empty())
        for (auto& ch : g_ch) if (playable(ch) && !inst_ver(ch).empty()) write_mod_settings(ch, g_prof);
    if (!probe_of(g_servers[i])) start_probe(false);
}

// ------------------------------------------------------------------ friends page (basics: no online status yet)
static std::vector<Friend> g_met;           // players met, newest first (refreshed when the page opens)
static void friends_refresh() {
    std::vector<std::wstring> dirs;
    for (auto& ch : g_ch) if (!ch.dir.empty()) dirs.push_back(bin_dir(ch) + L"\\ue4ss\\Mods\\PoppyCoop");
    g_met = players_met(dirs, g_prof.name);
    friends_update_from(g_met);
}
static void do_play();
// join a friend's room: picks their chapter and starts the game right away (chapter 0 = unknown: the selected one)
static void join_friend_room(const Friend& f, int chapter = 0) {
    g_prof.join_code = f.room;
    g_prof.tab = 2;
    for (size_t i = 0; chapter > 0 && i < g_ch.size(); i++) if (g_ch[i].num == chapter && playable(g_ch[i])) { g_sel = (int)i; break; }
    save_profile();
    g_page = Page::Chapter;
    g_focus = {};
    if (chapter > 0 && cur().num != chapter) { toast(tr(L"Chapter ") + std::to_wstring(chapter) + tr(L" isn't set up here yet - room code filled in.")); return; }
    for (size_t i = 0; i < g_ch.size() && i < 8; i++)
        if (g_running[i]) { toast(tr(L"Room code of ") + f.name + L": " + f.room + tr(L" - close the game, then press PLAY.")); return; }
    toast(tr(L"Joining ") + f.name + L" (" + f.room + L")...");
    do_play();
}
static void add_friend_toast(const Friend& f, AddResult r) {
    switch (r) {
    case AddResult::Added: toast(friend_code(f) + tr(L" is now your friend.")); break;
    case AddResult::Already: toast(friend_code(f) + tr(L" is already your friend.")); break;
    case AddResult::NeedsTag: toast(tr(L"Enter the whole friend code with the number, e.g. Max#12345.")); break;
    case AddResult::Self: toast(tr(L"That's your own friend code.")); break;
    case AddResult::Full: toast(tr(L"The friend list is full.")); break;
    default: toast(tr(L"Type your friend's code first (Name#12345).")); break;
    }
}
// ---- friends server
static HelloInfo hello_info() {
    HelloInfo hi;
    hi.name = clean_name(g_prof.name.empty() ? L"Player" : g_prof.name);
    hi.tag = player_tag();
    for (size_t i = 0; i < g_ch.size() && i < 8; i++)
        if (g_running[i]) { hi.ingame = true; hi.chapter = g_ch[i].num; hi.room = room_for(g_prof); break; }
    for (auto& c : hi.room) c = towupper(c);
    std::wstring keep;
    for (wchar_t c : hi.room) if ((c >= L'A' && c <= L'Z') || (c >= L'0' && c <= L'9') || c == L'-') keep += c;
    hi.room = keep.substr(0, 16);
    return hi;
}
// hello (optional) + list, in the background
static void friends_net_sync(bool hello) {
    if (g_fnet_busy) return;
    g_fnet_busy = true;
    if (hello) g_fnet_hello_at = GetTickCount64();
    HelloInfo hi = hello_info();
    std::thread([w = g_wnd, hello, hi] {
        auto* r = new FriendsResult();
        std::wstring new_tag;
        bool ok = true;
        if (hello) {
            FriendsResult h = api_hello(hi, new_tag);
            ok = h.reachable && h.error.empty();
            if (!ok) { *r = h; }
        }
        if (ok) *r = api_action("list", L"/v1/list", {});
        if (r->error == "not_registered" && !hello) {        // first contact: register, then list
            FriendsResult h = api_hello(hi, new_tag);
            if (h.reachable && h.error.empty()) *r = api_action("list", L"/v1/list", {});
            else *r = h;
        }
        if (!new_tag.empty()) r->ok_word = "newtag:" + utf8(new_tag);
        if (!PostMessageW(w, WM_APP_FRIENDS, 0, (LPARAM)r)) delete r;
    }).detach();
}
// an action (request / respond / remove), then the list again
static void friends_net_do(const char* action, const wchar_t* path, std::vector<std::pair<std::string, std::string>> fields) {
    if (g_fnet_busy) { toast(tr(L"One moment...")); return; }
    g_fnet_busy = true;
    std::string act = action;
    std::wstring wpath = path;
    std::thread([w = g_wnd, act, wpath, fields] {
        auto* r = new FriendsResult(api_action(act.c_str(), wpath.c_str(), fields));
        if (r->reachable && r->error.empty()) {
            FriendsResult l = api_action("list", L"/v1/list", {});
            if (l.reachable && l.error.empty()) { r->has_list = true; r->friends = l.friends; r->incoming = l.incoming; r->outgoing = l.outgoing; }
        }
        if (!PostMessageW(w, WM_APP_FRIENDS, 0, (LPARAM)r)) delete r;
    }).detach();
}
static std::wstring fnet_error_text(const std::string& e) {
    if (e == "not_found") return tr(L"No player with that friend code.");
    if (e == "self") return tr(L"That's your own friend code.");
    if (e == "already") return tr(L"You are already friends.");
    if (e == "limit") return tr(L"Too many requests - try again later.");
    if (e == "bad_auth") return tr(L"Friends server: your account key doesn't match.");
    if (e == "not_friends") return tr(L"You can only invite friends.");
    return tr(L"Friends server error: ") + wide(e);
}
static void on_friends_result(FriendsResult* r) {
    g_fnet_busy = false;
    if (r->ok_word.rfind("newtag:", 0) == 0) {          // our number was taken on the server: use the new one everywhere
        set_player_tag(wide(r->ok_word.substr(7)));
        for (auto& ch : g_ch) if (playable(ch) && !inst_ver(ch).empty()) write_mod_settings(ch, g_prof);
        toast(tr(L"Your friend code is now ") + clean_name(g_prof.name) + L"#" + player_tag());
    }
    if (!r->reachable || r->error == "not_set_up") { g_fnet_state = 2; return; }
    g_fnet_state = 1;
    if (r->has_list || (r->action == "list" && r->error.empty())) {
        for (auto& v : r->invites) {                    // a new invite: tell the player even on another page
            bool seen = false;
            for (auto& o : g_fnet.invites) if (o.code == v.code && o.room == v.room) seen = true;
            if (!seen) {
                toast(v.code + tr(L" invites you - open Friends to join."));
                FLASHWINFO fw = { sizeof(fw), g_wnd, FLASHW_TRAY | FLASHW_TIMERNOFG, 3, 0 };
                FlashWindowEx(&fw);
            }
        }
        g_fnet.friends = r->friends; g_fnet.incoming = r->incoming; g_fnet.outgoing = r->outgoing; g_fnet.invites = r->invites;
    }
    if (r->action == "request") {
        if (r->error.empty()) toast(r->ok_word == "friends" ? tr(L"You are friends now!") : tr(L"Friend request sent."));
        else toast(fnet_error_text(r->error));
    } else if (r->action == "respond" && r->error.empty()) {
        toast(r->ok_word == "friends" ? tr(L"You are friends now!") : tr(L"Request declined."));
    } else if (r->action == "remove" && r->error.empty()) {
        toast(tr(L"Removed."));
    } else if (r->action == "invite") {
        if (r->error.empty()) { if (r->ok_word == "invited") toast(tr(L"Invite sent - they see it in their launcher.")); }
        else if (r->error == "not_found") toast(tr(L"Invites need the new friends server - coming soon."));
        else toast(fnet_error_text(r->error));
    } else if (!r->error.empty() && r->action != "list" && r->action != "hello") {
        toast(fnet_error_text(r->error));
    }
}
// a friend code: the name bold, "#12345" behind it small and dim, so the name stands out
static void draw_code(int x, int y, int w, const std::wstring& code, const std::wstring& after = L"") {
    size_t k = code.find(L'#');
    std::wstring name = k == std::wstring::npos ? code : code.substr(0, k);
    std::wstring tag = k == std::wstring::npos ? L"" : code.substr(k);
    int nw = std::min(w, text_w(name, F_BOLD));
    text(R(x, y, nw + 2, 20), name, F_BOLD, C_TEXT, DT_LEFT | DT_SINGLELINE | DT_END_ELLIPSIS);
    int tx = x + nw + 2;
    if (!tag.empty() && tx < x + w) {
        text(R(tx, y + 3, x + w - tx, 18), tag, F_SMALL, mix(C_DIM, C_CARD, 0.25), DT_LEFT | DT_SINGLELINE | DT_END_ELLIPSIS);
        tx += text_w(tag, F_SMALL) + 2;
    }
    if (!after.empty() && tx < x + w) text(R(tx, y, x + w - tx, 20), after, F_BOLD, C_TEXT, DT_LEFT | DT_SINGLELINE | DT_END_ELLIPSIS);
}
static void draw_friends_local(int h);
static void draw_friends(int h) {
    if (g_fnet_state != 1) { draw_friends_local(h); return; }
    text(R(MX, 28, MW, 18), tr(L"FRIENDS"), F_SMALL, acc_text(), DT_LEFT | DT_SINGLELINE);
    text(R(MX, 46, MW - 330, 40), tr(L"Your friends"), F_H1, C_TEXT, DT_LEFT | DT_SINGLELINE);
    std::wstring mine = clean_name(g_prof.name.empty() ? L"Player" : g_prof.name) + L"#" + player_tag();
    text(R(MX + MW - 330, 40, 200, 16), tr(L"YOUR FRIEND CODE"), F_SMALL, C_DIM, DT_LEFT | DT_SINGLELINE);
    text(R(MX + MW - 330, 56, 200, 26), mine, F_BOLD, C_TEXT, DT_LEFT | DT_SINGLELINE | DT_END_ELLIPSIS);
    button(MX + MW - 120, 48, 120, 34, tr(L"Copy"), Btn::Secondary, [mine] { copy_text(mine); toast(tr(L"Copied: ") + mine); });
    text(R(MX, 92, MW, 20), tr(L"Send a friend request with their friend code. Friends see each other online and can join each other."), F_BODY, C_DIM, DT_LEFT | DT_SINGLELINE | DT_END_ELLIPSIS);
    textbox(MX, 124, 300, 40, &g_friend_edit, FRIEND_NAME_MAX + 6, false, tr(L"Friend code, e.g. Max#12345"), F_BODY);
    button(MX + 312, 126, 170, 36, tr(L"Send request"), Btn::Primary, [] {
        Friend f = parse_code(g_friend_edit);
        if (f.name.empty() || f.tag.empty()) { toast(tr(L"Enter the whole friend code with the number, e.g. Max#12345.")); return; }
        friends_net_do("request", L"/v1/request", { { "code", utf8(friend_code(f)) } });
        g_friend_edit.clear();
    });
    int y = 178;
    // invites into a friend's room: one click joins (starts the game)
    for (size_t i = 0; i < g_fnet.invites.size() && y < h - 200; i++) {
        const NetInvite v = g_fnet.invites[i];
        RECT r = R(MX, y, MW, 50);
        fill(r, mix(C_CARD, C_OK, 0.16), 10);
        draw_code(MX + 18, y + 6, MW - 380, v.code, tr(L" invites you"));
        text(R(MX + 18, y + 26, MW - 380, 18), tr(L"Chapter ") + std::to_wstring(v.chapter) + tr(L" - room ") + v.room, F_SMALL, C_DIM, DT_LEFT | DT_SINGLELINE);
        button(MX + MW - 330, y + 8, 180, 34, tr(L"Join now"), Btn::Primary, [v] {
            friends_net_do("invite", L"/v1/invite", { { "code", utf8(v.code) }, { "dismiss", "1" } });
            join_friend_room(Friend{ parse_code(v.code).name, L"", v.room }, v.chapter);
        });
        button(MX + MW - 140, y + 8, 124, 34, tr(L"Dismiss"), Btn::Ghost, [v] { friends_net_do("invite", L"/v1/invite", { { "code", utf8(v.code) }, { "dismiss", "1" } }); });
        y += 56;
    }
    // incoming requests
    for (size_t i = 0; i < g_fnet.incoming.size() && y < h - 200; i++) {
        std::wstring code = g_fnet.incoming[i];
        RECT r = R(MX, y, MW, 50);
        fill(r, mix(C_CARD, accent(), 0.12), 10);
        draw_code(MX + 18, y + 6, MW - 380, code);
        text(R(MX + 18, y + 26, MW - 380, 18), tr(L"wants to be your friend"), F_SMALL, C_DIM, DT_LEFT | DT_SINGLELINE);
        button(MX + MW - 330, y + 8, 180, 34, tr(L"Accept"), Btn::Primary, [code] { friends_net_do("respond", L"/v1/respond", { { "code", utf8(code) }, { "accept", "1" } }); });
        button(MX + MW - 140, y + 8, 124, 34, tr(L"Decline"), Btn::Ghost, [code] { friends_net_do("respond", L"/v1/respond", { { "code", utf8(code) }, { "accept", "0" } }); });
        y += 56;
    }
    if (g_fnet.friends.empty() && g_fnet.incoming.empty())
        text(R(MX, y, MW, 30), tr(L"No friends yet - send a request with a friend code, or to someone you played with below."), F_SMALL, C_DIM);
    for (size_t i = 0; i < g_fnet.friends.size() && y < h - 200; i++) {
        const NetFriend f = g_fnet.friends[i];
        RECT r = R(MX, y, MW, 50);
        fill(r, mix(C_CARD, C_CARD2, anim(akey(51, (int)i, 0), hover(r) ? 0.7 : 0.0, 16)), 10);
        circle(MX + 22, y + 25, 6, f.online ? C_OK : mix(C_DIM, C_CARD, 0.4));
        draw_code(MX + 38, y + 6, MW - 400, f.code);
        std::wstring st = !f.online ? tr(L"Offline") : f.chapter > 0 ? tr(L"Playing Chapter ") + std::to_wstring(f.chapter) + (f.room.empty() ? L"" : tr(L" - room ") + f.room) : tr(L"Online");
        text(R(MX + 38, y + 26, MW - 400, 18), st, F_SMALL, f.online ? C_OK : C_DIM, DT_LEFT | DT_SINGLELINE | DT_END_ELLIPSIS);
        if (f.online && !f.room.empty()) {
            Friend jf{ parse_code(f.code).name, L"", f.room };
            int fc = f.chapter;
            button(MX + MW - 330, y + 8, 180, 34, tr(L"Join"), Btn::Secondary, [jf, fc] { join_friend_room(jf, fc); });
        } else if (f.online) {                         // in the launcher: invite them into my room
            std::wstring code = f.code;
            button(MX + MW - 330, y + 8, 180, 34, tr(L"Invite"), Btn::Secondary, [code] {
                std::wstring room = hello_info().room;
                int chn = cur().num;
                if (room.empty()) { room = room_for(g_prof); for (auto& c : room) c = towupper(c); }
                for (size_t k = 0; k < g_ch.size() && k < 8; k++) if (g_running[k]) chn = g_ch[k].num;
                if (room.empty()) { toast(tr(L"Pick Create Game first - then invite.")); return; }
                friends_net_do("invite", L"/v1/invite", { { "code", utf8(code) }, { "chapter", std::to_string(chn) }, { "room", utf8(room) } });
            });
        }
        button(MX + MW - 140, y + 8, 124, 34, tr(L"Remove"), Btn::Ghost, [f] { friends_net_do("remove", L"/v1/remove", { { "code", utf8(f.code) } }); });
        y += 56;
    }
    for (size_t i = 0; i < g_fnet.outgoing.size() && y < h - 170; i++) {
        std::wstring code = g_fnet.outgoing[i];
        text(R(MX, y + 4, MW - 160, 24), tr(L"Waiting for ") + code + tr(L" to accept"), F_SMALL, C_DIM, DT_LEFT | DT_VCENTER | DT_SINGLELINE);
        button(MX + MW - 140, y, 124, 30, tr(L"Cancel"), Btn::Ghost, [code] { friends_net_do("remove", L"/v1/remove", { { "code", utf8(code) } }); });
        y += 36;
    }
    // recently played with
    int ry = std::max(y + 20, h - 170);
    text(R(MX, ry, MW, 18), tr(L"RECENTLY PLAYED WITH"), F_SMALL, C_DIM, DT_LEFT | DT_SINGLELINE);
    int x = MX, n = 0;
    for (auto& m : g_met) {
        if (m.tag.empty()) continue;                       // older mod: no friend code to send a request to
        std::wstring code = friend_code(m);
        bool known = false;
        for (auto& f : g_fnet.friends) if (lower(f.code) == lower(code)) known = true;
        for (auto& o : g_fnet.outgoing) if (lower(o) == lower(code)) known = true;
        if (known) continue;
        std::wstring lbl = L"+ " + code;
        int bw = std::min(260, text_w(lbl, F_SMALL) + 40);
        if (x + bw > MX + MW) break;
        button(x, ry + 24, bw, 32, lbl, Btn::Ghost, [code] { friends_net_do("request", L"/v1/request", { { "code", utf8(code) } }); });
        x += bw + 8;
        n++;
    }
    if (n == 0) text(R(MX, ry + 24, MW, 18), tr(L"Nobody new yet - players show up here after you played together."), F_SMALL, C_DIM, DT_LEFT | DT_SINGLELINE);
}
// fallback without the friends server: the local list (names + last room)
static void draw_friends_local(int h) {
    text(R(MX, 28, MW, 18), tr(L"FRIENDS"), F_SMALL, acc_text(), DT_LEFT | DT_SINGLELINE);
    text(R(MX, 46, MW - 330, 40), tr(L"Your friends"), F_H1, C_TEXT, DT_LEFT | DT_SINGLELINE);
    // own friend code
    std::wstring mine = clean_name(g_prof.name.empty() ? L"Player" : g_prof.name) + L"#" + player_tag();
    text(R(MX + MW - 330, 40, 200, 16), tr(L"YOUR FRIEND CODE"), F_SMALL, C_DIM, DT_LEFT | DT_SINGLELINE);
    text(R(MX + MW - 330, 56, 200, 26), mine, F_BOLD, C_TEXT, DT_LEFT | DT_SINGLELINE | DT_END_ELLIPSIS);
    button(MX + MW - 120, 48, 120, 34, tr(L"Copy"), Btn::Secondary, [mine] { copy_text(mine); toast(tr(L"Copied: ") + mine); });
    text(R(MX, 92, MW, 20), tr(L"Add friends with their friend code. Their last room is remembered - join it with one click."), F_BODY, C_DIM, DT_LEFT | DT_SINGLELINE | DT_END_ELLIPSIS);

    // add by code
    textbox(MX, 124, 300, 40, &g_friend_edit, FRIEND_NAME_MAX + 6, false, tr(L"Friend code, e.g. Max#12345"), F_BODY);
    button(MX + 312, 126, 120, 36, tr(L"Add"), Btn::Primary, [] {
        Friend f = parse_code(g_friend_edit);
        for (auto& m : g_met) if (same_player(m, f) && !f.tag.empty()) { f.room = m.room; break; }
        AddResult r = friend_add(f, true);
        add_friend_toast(f, r);
        if (r == AddResult::Added) g_friend_edit.clear();
    });

    // the list
    int y = 180;
    if (g_friends.empty())
        text(R(MX, y, MW, 40), tr(L"No friends yet - add a friend code above, or pick someone you played with below."), F_SMALL, C_DIM);
    int shown = 0;
    for (size_t i = 0; i < g_friends.size() && y < h - 230; i++, shown++) {
        const Friend f = g_friends[i];
        RECT r = R(MX, y, MW, 50);
        fill(r, mix(C_CARD, C_CARD2, anim(akey(50, (int)i, 0), hover(r) ? 0.7 : 0.0, 16)), 10);
        text(R(MX + 18, y + 6, MW - 360, 20), friend_code(f), F_BOLD, C_TEXT, DT_LEFT | DT_SINGLELINE | DT_END_ELLIPSIS);
        text(R(MX + 18, y + 26, MW - 360, 18), f.room.empty() ? tr(L"Not played together yet") : tr(L"Last room: ") + f.room,
             F_SMALL, C_DIM, DT_LEFT | DT_SINGLELINE | DT_END_ELLIPSIS);
        if (!f.room.empty())
            button(MX + MW - 330, y + 8, 180, 34, tr(L"Join their room"), Btn::Secondary, [f] { join_friend_room(f); });
        button(MX + MW - 140, y + 8, 124, 34, tr(L"Remove"), Btn::Ghost, [f] { friend_remove(f); toast(friend_code(f) + tr(L" removed.")); });
        y += 56;
    }
    if (shown < (int)g_friends.size())
        text(R(MX, y, MW, 18), L"+" + std::to_wstring(g_friends.size() - shown) + tr(L" more (make the window bigger)"), F_SMALL, C_DIM, DT_LEFT | DT_SINGLELINE);

    // recently played with (not friends yet)
    int ry = std::max(y + 24, h - 200);
    text(R(MX, ry, MW, 18), tr(L"RECENTLY PLAYED WITH"), F_SMALL, C_DIM, DT_LEFT | DT_SINGLELINE);
    int x = MX, row = 0, n = 0;
    for (auto& m : g_met) {
        if (friend_index(m) >= 0) continue;
        std::wstring lbl = L"+ " + friend_code(m);
        int bw = std::min(260, text_w(lbl, F_SMALL) + 40);
        if (x + bw > MX + MW) { x = MX; row++; }
        if (row > 1) break;
        Friend f = m;
        button(x, ry + 24 + row * 40, bw, 32, lbl, Btn::Ghost, [f] { add_friend_toast(f, friend_add(f, false)); });
        x += bw + 8;
        n++;
    }
    if (n == 0) text(R(MX, ry + 24, MW, 18), tr(L"Nobody new yet - names show up here after you played together."), F_SMALL, C_DIM, DT_LEFT | DT_SINGLELINE);
    text(R(MX, h - 60, MW, 18), g_fnet_state == 2 ? tr(L"Friends server not reachable - showing your local list.") : tr(L"Players with an older version show without a number. Online status and invites come later."), F_SMALL, g_fnet_state == 2 ? C_WARN : mix(C_DIM, C_BG, 0.3), DT_LEFT | DT_SINGLELINE);
}

static void draw_servers(int h) {
    text(R(MX, 28, MW, 18), tr(L"SERVERS"), F_SMALL, acc_text(), DT_LEFT | DT_SINGLELINE);
    text(R(MX, 46, MW - 160, 40), tr(L"Server & connection"), F_H1, C_TEXT, DT_LEFT | DT_SINGLELINE);
    button(MX + MW - 130, 50, 130, 36, g_probing ? tr(L"Testing...") : tr(L"Test again"), Btn::Ghost, [] { start_probe(true); }, !g_probing);
    text(R(MX, 92, MW, 20), tr(L"Everyone you play with has to pick the same server."), F_BODY, C_DIM, DT_LEFT | DT_SINGLELINE);

    for (int i = 0; i < (int)g_servers.size(); i++) {
        const Server& v = g_servers[i];
        int y = 124 + i * 66;
        RECT r = R(MX, y, MW, 58);
        bool sel = i == g_srv;
        double ht = anim(akey(40, i, 0), hover(r) ? 1.0 : 0.0, 16), st = anim(akey(41, i, 0), sel ? 1.0 : 0.0, 14);
        fill(r, mix(C_CARD, C_CARD2, ht * 0.7), 12);
        if (st > 0.02) frame(r, mix(C_CARD, accent(), st), 12, 2);
        // radio
        circle(MX + 24, y + 29, 9, mix(C_LINE, accent(), st));
        circle(MX + 24, y + 29, 7, C_CARD);
        if (st > 0.02) circle(MX + 24, y + 29, (int)(4 * st + 0.5), accent());
        text(R(MX + 44, y + 9, 300, 20), v.name, F_BOLD, C_TEXT, DT_LEFT | DT_SINGLELINE | DT_END_ELLIPSIS);
        std::wstring sub;
        if (v.kind == SrvKind::Relay && v.builtin) sub = L"Free relay (Cloudflare), nearest datacenter automatically";
        else if (v.kind == SrvKind::Relay) sub = L"Relay  \x00B7  " + v.addr;
        else if (v.kind == SrvKind::Host) sub = L"Your IP " + (g_lan.empty() ? std::wstring(L"(see your router)") : g_lan) + L"  \x00B7  UDP port 27777 open";
        else sub = L"Friend who hosts  \x00B7  " + v.addr + L":" + std::to_wstring(v.port);
        int right = v.builtin ? MW - 16 : MW - 50;
        text(R(MX + 44, y + 30, right - 260, 18), sub, F_SMALL, C_DIM, DT_LEFT | DT_SINGLELINE | DT_END_ELLIPSIS);
        // connection quality
        const Probe* p = probe_of(v);
        int qx = MX + right - 200;
        if (v.kind == SrvKind::Host) {
            text(R(qx + 34, y + 9, 166, 20), tr(L"You are the server"), F_SMALL, C_TEXT, DT_LEFT | DT_SINGLELINE);
            text(R(qx + 34, y + 29, 166, 18), tr(L"friends connect to you"), F_SMALL, C_DIM, DT_LEFT | DT_SINGLELINE);
        } else {
            signal_bars(qx, y + 18, p, akey(42, i, 0));
            COLORREF qc = p && p->done ? quality_color(quality(*p)) : C_DIM;
            text(R(qx + 34, y + 9, 166, 20), probe_text(v, p), F_SMALL, qc == C_DIM ? C_TEXT : qc, DT_LEFT | DT_SINGLELINE | DT_END_ELLIPSIS);
            std::wstring det;
            if (p && p->done && p->ms >= 0) {
                det = L"jitter " + std::to_wstring(p->jitter) + L" ms  \x00B7  " + std::to_wstring(p->loss) + L"% loss";
                if (!p->colo.empty()) det += L"  \x00B7  " + p->colo;
            }
            text(R(qx + 34, y + 29, 170, 18), det, F_SMALL, C_DIM, DT_LEFT | DT_SINGLELINE | DT_END_ELLIPSIS);
        }
        click(r, [i] { select_server(i); });
        if (!v.builtin) {
            bool conf = g_confirm_remove == i;
            button(MX + MW - 42, y + 15, conf ? 34 : 28, 28, conf ? tr(L"OK?") : L"x", conf ? Btn::Danger : Btn::Ghost, [i] {
                if (g_confirm_remove != i) { g_confirm_remove = i; return; }
                g_confirm_remove = -1;
                g_servers.erase(g_servers.begin() + i);
                if (g_srv == i) g_srv = 0; else if (g_srv > i) g_srv--;
                apply_server(); save_servers();
                if (!trim(g_prof.name).empty())
                    for (auto& ch : g_ch) if (playable(ch) && !inst_ver(ch).empty()) write_mod_settings(ch, g_prof);
            });
        }
    }

    // add a server
    int y = 124 + (int)g_servers.size() * 66 + 6;
    bool full = g_servers.size() >= 5;
    RECT card = R(MX, y, MW, 104);
    fill(card, C_CARD, 12);
    text(R(MX + 16, y + 10, 300, 18), full ? tr(L"ADD A SERVER (remove one first - 3 at most)") : tr(L"ADD A SERVER"), F_SMALL, acc_text(), DT_LEFT | DT_SINGLELINE);
    textbox(MX + 16, y + 32, 170, 40, &g_new_name, 24, false, L"Name", F_SMALL);
    textbox(MX + 196, y + 32, MW - 330, 40, &g_new_addr, 120, false, L"wss://... or IP of a friend who hosts", F_SMALL);
    button(MX + MW - 120, y + 32, 104, 40, tr(L"Add"), Btn::Primary, [] {
        Server v;
        if (!parse_server(g_new_addr, v)) { toast(tr(L"That doesn't look like a server address.")); return; }
        v.name = trim(g_new_name).empty() ? v.addr : trim(g_new_name);
        v.builtin = false;
        for (auto& o : g_servers) if (srv_key(o) == srv_key(v)) { toast(tr(L"That server is already in the list.")); return; }
        g_servers.push_back(v);
        g_new_name.clear(); g_new_addr.clear(); g_focus = {};
        select_server((int)g_servers.size() - 1);
        start_probe(true);
        toast(tr(L"Added ") + v.name + tr(L" - testing the connection..."));
    }, !full && !trim(g_new_addr).empty());
    text(R(MX + 16, y + 78, MW - 32, 18), tr(L"A relay address (wss://...) or a friend's IP, e.g. 203.0.113.5 or 203.0.113.5:27777"), F_SMALL, C_DIM, DT_LEFT | DT_SINGLELINE);
    (void)h;
}

// ------------------------------------------------------------------ paint
// Page / chapter / theme changes cross-fade: the previous frame is kept and blended out over the new one.
static HBITMAP g_last_bmp = nullptr, g_fade_bmp = nullptr;
static int g_bmp_w = 0, g_bmp_h = 0;
static ULONGLONG g_fade_t0 = 0;
static bool g_fade_full = false;
static long long g_last_sig = -1;
static const double FADE_MS = 230.0;

static int theme_index() { for (int i = 0; i < 3; i++) if (g_theme == THEMES[i].id) return i; return 0; }

static void update_zoom(int w, int h) {
    double z = std::min(w / g_dpi / BASE_W, h / g_dpi / BASE_H);
    z = std::max(1.0, std::min(2.5, z));
    double zmin = std::min(w / g_dpi / MIN_W, h / g_dpi / MIN_H);   // smaller than the minimum anyway: shrink
    if (zmin < 1.0) z = std::max(0.5, zmin);
    if (std::fabs(z - g_zoom) < 0.005) return;
    g_zoom = z; g_s = g_dpi * z;
    for (HFONT* f : { &F_LOGO, &F_H1, &F_H2, &F_BODY, &F_SMALL, &F_BOLD, &F_CODE, &F_BIG }) if (*f) DeleteObject(*f);
    make_fonts();
}
static void save_window_size() {
    WINDOWPLACEMENT wp = { sizeof(wp) };
    if (!g_wnd || !GetWindowPlacement(g_wnd, &wp)) return;
    if (wp.showCmd == SW_SHOWMINIMIZED) return;
    RECT r = wp.rcNormalPosition;
    ini_set(L"Launcher", L"WinW", std::to_wstring((int)((r.right - r.left) / g_dpi)));
    ini_set(L"Launcher", L"WinH", std::to_wstring((int)((r.bottom - r.top) / g_dpi)));
    ini_set(L"Launcher", L"WinMax", IsZoomed(g_wnd) ? L"1" : L"0");
}
// ------------------------------------------------------------------ a friend's settings
// The mod writes <mod>\settings_friend.txt when a friend in the room plays with other switches (speedrun, harder
// enemies, shared items...): "name=<friend>" + "<switch>=true|false" for each one that differs. The launcher
// offers to take them; then the game is closed and started again (same room), with the friend's switches.
struct SetOffer { int ch = -1; std::wstring name; std::vector<std::pair<std::wstring, bool>> keys; std::string raw; };
static SetOffer g_offer;
static void launch_now(int idx);
static std::string g_offer_dismissed;
static int g_restart_ch = -1;
static ULONGLONG g_restart_t0 = 0;
static void kill_game(const Chapter& c) {
    if (c.shipping.empty()) return;
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap == INVALID_HANDLE_VALUE) return;
    PROCESSENTRY32W pe = { sizeof(pe) };
    for (BOOL ok = Process32FirstW(snap, &pe); ok; ok = Process32NextW(snap, &pe)) {
        if (_wcsicmp(pe.szExeFile, c.shipping.c_str()) != 0) continue;
        HANDLE ph = OpenProcess(PROCESS_TERMINATE, FALSE, pe.th32ProcessID);
        if (ph) { TerminateProcess(ph, 0); CloseHandle(ph); }
    }
    CloseHandle(snap);
}
static const SyncOpt* sync_opt(const Chapter& c, const std::wstring& id) {
    for (auto& o : c.sync) if (id == o.id) return &o;
    return nullptr;
}
static void poll_settings_offer() {
    SetOffer o;
    for (size_t i = 0; i < g_ch.size() && i < 8; i++) {
        if (!g_running[i]) continue;
        std::string s;
        if (!read_file(mod_dir(g_ch[i]) + L"\\settings_friend.txt", s) || s.empty() || s.size() > 4096) continue;
        o.ch = (int)i; o.raw = s;
        size_t p = 0;
        while (p < s.size()) {
            size_t e = s.find('\n', p);
            if (e == std::string::npos) e = s.size();
            std::string line = s.substr(p, e - p);
            p = e + 1;
            if (!line.empty() && line.back() == '\r') line.pop_back();
            size_t eq = line.find('=');
            if (eq == std::string::npos) continue;
            std::wstring k = wide(line.substr(0, eq)), v = wide(line.substr(eq + 1));
            if (k == L"name") o.name = v.substr(0, 32);
            else if ((v == L"true" || v == L"false") && sync_opt(g_ch[i], k)) o.keys.push_back({ k, v == L"true" });
        }
        if (o.keys.empty()) o = SetOffer();
        break;
    }
    bool fresh = o.raw != g_offer.raw && !o.raw.empty() && o.raw != g_offer_dismissed;
    bool changed = o.raw != g_offer.raw;
    g_offer = o;
    if (fresh) {
        FLASHWINFO fw = { sizeof(fw), g_wnd, FLASHW_TRAY | FLASHW_TIMERNOFG, 5, 0 };
        FlashWindowEx(&fw);
    }
    if (changed) InvalidateRect(g_wnd, nullptr, FALSE);
}
static bool offer_open() { return g_offer.ch >= 0 && !g_offer.raw.empty() && g_offer.raw != g_offer_dismissed && g_restart_ch < 0; }
static void take_offer() {
    if (g_offer.ch < 0 || g_offer.ch >= (int)g_ch.size()) return;
    Chapter& c = g_ch[g_offer.ch];
    for (auto& kv : g_offer.keys) for (auto& o : c.sync) if (kv.first == o.id) o.value = kv.second;
    chapter_save_settings(c);
    DeleteFileW((mod_dir(c) + L"\\settings_friend.txt").c_str());
    g_offer_dismissed = g_offer.raw;
    g_restart_ch = g_offer.ch; g_restart_t0 = GetTickCount64();
    kill_game(c);
    toast(tr(L"Taking the settings - the game restarts..."));
}
// called from the poll timer: start the game again once the old one is gone
static void restart_tick() {
    if (g_restart_ch < 0) return;
    ULONGLONG t = GetTickCount64() - g_restart_t0;
    if (!game_running(g_ch[g_restart_ch]) && t > 2500) {
        int idx = g_restart_ch;
        g_restart_ch = -1;
        launch_now(idx);
    } else if (t > 20000) {
        g_restart_ch = -1;
        toast(tr(L"The game didn't close - close it, then press PLAY."));
    }
}

static void draw_crash_consent(int w_px, int h_px) {
    if (!FEATURE_ONLINE || g_crashrep != -1) return;
    g_hits.push_back({ { 0, 0, w_px, h_px }, [] {}, false });          // the page below doesn't react meanwhile
    {   // dim the page behind the card
        BITMAPINFO bi = {}; bi.bmiHeader = { sizeof(BITMAPINFOHEADER), 1, 1, 1, 32, BI_RGB };
        void* bits = nullptr;
        HBITMAP b = CreateDIBSection(g_dc, &bi, DIB_RGB_COLORS, &bits, nullptr, 0);
        if (b && bits) {
            *(DWORD*)bits = 0;
            HDC m = CreateCompatibleDC(g_dc);
            HGDIOBJ o = SelectObject(m, b);
            BLENDFUNCTION bf = { AC_SRC_OVER, 0, 150, 0 };
            AlphaBlend(g_dc, 0, 0, w_px, h_px, m, 0, 0, 1, 1, bf);
            SelectObject(m, o); DeleteDC(m);
        }
        if (b) DeleteObject(b);
    }
    const int CW = 540, CH = 268;
    int lw = (int)(w_px / g_s), lh = (int)(h_px / g_s);
    int x = std::max(MX, (lw - CW) / 2), y = std::max(80, (lh - CH) / 2 - 20);
    RECT card = R(x, y, CW, CH);
    fill(card, C_CARD2, 16);
    frame(card, accent(), 16, 2);
    text(R(x + 28, y + 24, CW - 56, 18), tr(L"CRASH REPORTS"), F_SMALL, acc_text(), DT_LEFT | DT_SINGLELINE);
    text(R(x + 28, y + 44, CW - 56, 30), tr(L"Send crash reports to the developers?"), F_BIG, C_TEXT, DT_LEFT | DT_SINGLELINE);
    text(R(x + 28, y + 86, CW - 56, 100), tr(L"When the game crashes, the launcher can send the error message, the end of the mod's log, the mod version and your Windows version to the PoppyCoop developers. User names in folder paths are removed. It helps us fix crashes. You can change this any time in the launcher settings."), F_SMALL, C_DIM);
    button(x + 28, y + CH - 64, 220, 40, tr(L"Yes, send them"), Btn::Primary, [] { set_crash_consent(true); });
    button(x + 260, y + CH - 64, 120, 40, tr(L"No"), Btn::Ghost, [] { set_crash_consent(false); });
}

static void draw_settings_offer(int w_px, int h_px) {
    if (!offer_open() || (FEATURE_ONLINE && g_crashrep == -1)) return;
    g_hits.push_back({ { 0, 0, w_px, h_px }, [] {}, false });
    {   // dim the page behind the card
        BITMAPINFO bi = {}; bi.bmiHeader = { sizeof(BITMAPINFOHEADER), 1, 1, 1, 32, BI_RGB };
        void* bits = nullptr;
        HBITMAP b = CreateDIBSection(g_dc, &bi, DIB_RGB_COLORS, &bits, nullptr, 0);
        if (b && bits) {
            *(DWORD*)bits = 0;
            HDC m = CreateCompatibleDC(g_dc);
            HGDIOBJ o = SelectObject(m, b);
            BLENDFUNCTION bf = { AC_SRC_OVER, 0, 150, 0 };
            AlphaBlend(g_dc, 0, 0, w_px, h_px, m, 0, 0, 1, 1, bf);
            SelectObject(m, o); DeleteDC(m);
        }
        if (b) DeleteObject(b);
    }
    const Chapter& c = g_ch[g_offer.ch];
    int rows = (int)std::min<size_t>(g_offer.keys.size(), 8);
    const int CW = 560, CH = 230 + rows * 26;
    int lw = (int)(w_px / g_s), lh = (int)(h_px / g_s);
    int x = std::max(MX, (lw - CW) / 2), y = std::max(60, (lh - CH) / 2 - 20);
    RECT card = R(x, y, CW, CH);
    fill(card, C_CARD2, 16);
    frame(card, accent(), 16, 2);
    text(R(x + 28, y + 22, CW - 56, 18), tr(L"FRIEND'S SETTINGS"), F_SMALL, acc_text(), DT_LEFT | DT_SINGLELINE);
    text(R(x + 28, y + 42, CW - 56, 30), (g_offer.name.empty() ? L"?" : g_offer.name) + tr(L" plays with other settings"), F_BIG, C_TEXT, DT_LEFT | DT_SINGLELINE | DT_END_ELLIPSIS);
    text(R(x + 28, y + 80, CW - 56, 44), tr(L"Different settings make different games (items, doors, enemies). Take theirs? The game restarts and you join the same room again."), F_SMALL, C_DIM);
    int ry = y + 130;
    for (int i = 0; i < rows; i++) {
        const auto& kv = g_offer.keys[i];
        const SyncOpt* o = sync_opt(c, kv.first);
        std::wstring label = o ? tr(o->label) : kv.first;
        text(R(x + 28, ry, CW - 300, 22), label, F_BODY, C_TEXT, DT_LEFT | DT_SINGLELINE | DT_END_ELLIPSIS);
        std::wstring val = tr(L"friend: ") + tr(kv.second ? L"On" : L"Off") + L"   " + tr(L"you: ") + tr(kv.second ? L"Off" : L"On");
        text(R(x + CW - 270, ry, 242, 22), val, F_SMALL, kv.second ? C_OK : C_DIM, DT_RIGHT | DT_SINGLELINE);
        ry += 26;
    }
    button(x + 28, y + CH - 62, 250, 40, tr(L"Take them & restart"), Btn::Primary, [] { take_offer(); });
    button(x + 290, y + CH - 62, 150, 40, tr(L"Keep mine"), Btn::Ghost, [] { g_offer_dismissed = g_offer.raw; });
}

static void draw_title_bar(int w, int tb) {
    RECT bar = { 0, -tb, w, 0 };
    fill(bar, C_SIDE);
    int is = (int)(16 * g_dpi + 0.5);
    DrawIconEx(g_dc, (int)(10 * g_dpi), -tb + (tb - is) / 2, LoadIconW(GetModuleHandleW(nullptr), MAKEINTRESOURCEW(1)), is, is, 0, nullptr, DI_NORMAL);
    bool active = GetForegroundWindow() == g_wnd;
    RECT tr_ = { (int)(34 * g_dpi), -tb, w - 3 * (int)(TITLE_BTN_W * g_dpi), 0 };
    text(tr_, L"Poppy Playtime Co-op", F_SMALL, active ? C_TEXT : C_DIM, DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS);
    const int bw = (int)(TITLE_BTN_W * g_dpi + 0.5), g = (int)(5 * g_dpi + 0.5);
    for (int i = 0; i < 3; i++) {                  // 0 minimize, 1 maximize / restore, 2 close
        RECT r = { w - (3 - i) * bw, -tb, w - (2 - i) * bw, 0 };
        bool hv = hover(r);
        if (hv) fill(r, i == 2 ? RGB(196, 43, 28) : C_CARD2);
        COLORREF c = hv && i == 2 ? RGB(255, 255, 255) : active ? C_TEXT : C_DIM;
        int cx = (r.left + r.right) / 2, cy = (r.top + r.bottom) / 2;
        HPEN pen = CreatePen(PS_SOLID, std::max(1, (int)(g_dpi + 0.5)), c);
        HGDIOBJ op = SelectObject(g_dc, pen), ob = SelectObject(g_dc, GetStockObject(NULL_BRUSH));
        if (i == 0) { MoveToEx(g_dc, cx - g, cy, nullptr); LineTo(g_dc, cx + g + 1, cy); }
        else if (i == 1 && !IsZoomed(g_wnd)) Rectangle(g_dc, cx - g, cy - g, cx + g + 1, cy + g + 1);
        else if (i == 1) {
            Rectangle(g_dc, cx - g, cy - g + 2, cx + g - 1, cy + g + 1);
            MoveToEx(g_dc, cx - g + 2, cy - g + 2, nullptr); LineTo(g_dc, cx - g + 2, cy - g); LineTo(g_dc, cx + g, cy - g); LineTo(g_dc, cx + g, cy + g - 2); LineTo(g_dc, cx + g - 2, cy + g - 2);
        } else {
            MoveToEx(g_dc, cx - g, cy - g, nullptr); LineTo(g_dc, cx + g + 1, cy + g + 1);
            MoveToEx(g_dc, cx + g, cy - g, nullptr); LineTo(g_dc, cx - g - 1, cy + g + 1);
        }
        SelectObject(g_dc, op); SelectObject(g_dc, ob); DeleteObject(pen);
        g_hits.push_back({ r, [i] {
            if (i == 0) PostMessageW(g_wnd, WM_SYSCOMMAND, SC_MINIMIZE, 0);
            else if (i == 1) PostMessageW(g_wnd, WM_SYSCOMMAND, IsZoomed(g_wnd) ? SC_RESTORE : SC_MAXIMIZE, 0);
            else PostMessageW(g_wnd, WM_CLOSE, 0, 0);
        }, false });
    }
}

static void paint(HDC wdc, int w, int h) {
    ULONGLONG now = GetTickCount64();
    g_dt = g_frame_ms ? std::min(0.05, (now - g_frame_ms) / 1000.0) : 0.0;
    g_frame_ms = now;
    g_moving = false;

    HDC dc = CreateCompatibleDC(wdc);
    HBITMAP bmp = CreateCompatibleBitmap(wdc, w, h);
    HGDIOBJ old = SelectObject(dc, bmp);
    g_dc = dc;
    SetBkMode(dc, TRANSPARENT);
    g_hits.clear();
    const int tb = bar_h();
    SetViewportOrgEx(dc, 0, tb, nullptr);          // the pages draw below the own title bar (it sits at y -tb..0)
    RECT all = { 0, -tb, w, h };
    fill(all, C_BG);
    update_zoom(w, h - tb);
    int lh = (int)((h - tb) / g_s);
    MW = std::max(636, (int)(w / g_s) - MX - 32);
    draw_sidebar(lh);
    g_view = 0;
    if (g_page == Page::Settings && playable(cur())) draw_settings(lh);
    else if (g_page == Page::Profile) draw_profile(lh);
    else if (g_page == Page::Welcome) draw_welcome(lh);
    else if (g_page == Page::App) draw_app(lh);
    else if (g_page == Page::Servers) draw_servers(lh);
    else if (g_page == Page::Friends) draw_friends(lh);
    else if (g_page == Page::Logs && playable(cur())) draw_logs(lh);
    else if (g_page == Page::News) draw_news(lh);
    else draw_chapter(lh);

    // toast: fades and slides in, fades out
    bool tv = !g_toast.empty() && now < g_toast_until;
    double ta = anim(akey(5, 0, 0), tv ? 1.0 : 0.0, 12);
    if (ta > 0.01 && !g_toast.empty()) {
        int tw = text_w(g_toast, F_SMALL) + 36;
        RECT r = R(MX + (MW - tw) / 2, lh - 150 + (int)((1 - ta) * 12), tw, 34);
        fill(r, mix(C_BG, C_CARD2, ta), 17);
        text(r, g_toast, F_SMALL, mix(C_BG, C_TEXT, ta), DT_CENTER | DT_VCENTER | DT_SINGLELINE);
    }
    bool upd = !g_latest.empty() && version_newer(g_latest, MOD_VERSION);
    text(R(MX, lh - 26, MW - (upd ? 260 : 136), 18), L"mod v" MOD_VERSION L"  \x00B7  Launcher " LAUNCHER_VERSION L"  \x00B7  " + tr(L"Fan-made co-op mod. Not affiliated with Mob Entertainment."),
         F_SMALL, mix(C_DIM, C_BG, 0.35), DT_LEFT | DT_SINGLELINE | DT_END_ELLIPSIS);
    // what's new / newer release on GitHub
    if (upd)
        button(MX + MW - 250, lh - 34, 250, 28, g_updating ? tr(L"Updating...") : tr(L"Update v") + g_latest + tr(L" available - install"), Btn::Primary, [] {
            if (g_updating) return;
            bool running = false;
            for (size_t i = 0; i < g_ch.size() && i < 8; i++) if (g_running[i]) running = true;
            if (running) { toast(tr(L"Close the game first.")); return; }
            if (g_latest_zip.empty() && g_latest_exe.empty()) { ShellExecuteW(nullptr, L"open", RELEASES_PAGE, nullptr, nullptr, SW_SHOWNORMAL); return; }
            start_self_update();
        });
    else
        button(MX + MW - 130, lh - 34, 130, 28, tr(L"What's new"), Btn::Ghost, [] {
            if (g_page != Page::News) g_news_back = g_page;
            g_page = Page::News; g_focus = {}; g_capture = -1;
        });

    draw_crash_consent(w, h - tb);
    draw_settings_offer(w, h - tb);
    if (tb) draw_title_bar(w, tb);
    SetViewportOrgEx(dc, 0, 0, nullptr);

    // cross-fade
    long long sig = theme_index() * 100000LL + (long long)g_page * 1000 + g_sel * 10 + g_view;
    if (w != g_bmp_w || h != g_bmp_h) {
        if (g_last_bmp) DeleteObject(g_last_bmp);
        if (g_fade_bmp) { DeleteObject(g_fade_bmp); g_fade_bmp = nullptr; }
        g_last_bmp = CreateCompatibleBitmap(wdc, w, h); g_bmp_w = w; g_bmp_h = h; g_last_sig = -1;
    }
    HDC tmp = CreateCompatibleDC(wdc);
    if (g_last_sig != -1 && sig != g_last_sig && g_anims) {
        if (!g_fade_bmp) g_fade_bmp = CreateCompatibleBitmap(wdc, w, h);
        HDC fd = CreateCompatibleDC(wdc);
        HGDIOBJ o1 = SelectObject(fd, g_fade_bmp), o2 = SelectObject(tmp, g_last_bmp);
        BitBlt(fd, 0, 0, w, h, tmp, 0, 0, SRCCOPY);
        SelectObject(fd, o1); SelectObject(tmp, o2); DeleteDC(fd);
        g_fade_full = sig / 100000 != g_last_sig / 100000;   // theme change: whole window
        g_fade_t0 = now;
    }
    g_last_sig = sig;
    HGDIOBJ o = SelectObject(tmp, g_last_bmp);
    BitBlt(tmp, 0, 0, w, h, dc, 0, 0, SRCCOPY);                // the clean frame, for the next fade
    SelectObject(tmp, o);
    if (g_fade_bmp) {
        double t = ease((now - g_fade_t0) / FADE_MS);
        if (t >= 1) { DeleteObject(g_fade_bmp); g_fade_bmp = nullptr; }
        else {
            int x0 = g_fade_full ? 0 : S(284);
            HGDIOBJ o3 = SelectObject(tmp, g_fade_bmp);
            BLENDFUNCTION bf = { AC_SRC_OVER, 0, (BYTE)(255 * (1 - t)), 0 };
            AlphaBlend(dc, x0, 0, w - x0, h, tmp, x0, 0, w - x0, h, bf);
            SelectObject(tmp, o3);
            g_moving = true;
        }
    }
    DeleteDC(tmp);

    BitBlt(wdc, 0, 0, w, h, dc, 0, 0, SRCCOPY);
    SelectObject(dc, old);
    DeleteObject(bmp);
    DeleteDC(dc);
    if (g_moving) SetTimer(g_wnd, TIMER_ANIM, 15, nullptr); else KillTimer(g_wnd, TIMER_ANIM);
}

// ------------------------------------------------------------------ install / play
// writes UE4SS + the mod into the chapter's folder; w (may be null) gets progress messages
static bool install_files(const Chapter& c, const Profile& p, HWND w) {
    auto items = install_items(c);
    size_t total = 0, done = 0;
    std::vector<std::pair<const void*, DWORD>> data;
    for (auto& it : items) {
        const void* d = nullptr; DWORD n = 0;
        if (!load_res(it.res, &d, &n)) return false;
        data.push_back({ d, n }); total += n;
    }
    bool ok = true;
    std::wstring base = bin_dir(c);
    for (size_t i = 0; i < items.size() && ok; i++) {
        std::wstring path = base + L"\\" + items[i].rel;
        if (!(items[i].keep_existing && file_exists(path))) ok = write_file(path, data[i].first, data[i].second);
        done += data[i].second;
        if (w) PostMessageW(w, WM_APP_PROGRESS, (WPARAM)(done * 100 / (total ? total : 1)), 0);
    }
    if (ok) ok = write_mod_settings(c, p);
    if (ok) ok = write_text(mod_dir(c) + L"\\version.txt", MOD_VERSION);
    return ok;
}

static void start_install(int ch, bool then_launch) {
    if (g_installing.exchange(true)) return;
    g_install_ch = ch; g_install_pct = 0; g_launch_after_install = then_launch;
    for (auto& a : g_anim) if (a.first == akey(6, 0, 0)) a.second = 0;
    Chapter c = g_ch[ch];         // copy for the worker
    Profile p = g_prof;
    p.name = clean_name(p.name);
    HWND w = g_wnd;
    std::thread([c, p, w] {
        bool ok = install_files(c, p, w);
        PostMessageW(w, WM_APP_INSTALLED, ok ? 1 : 0, 0);
    }).detach();
}

// names of the players met in a room (the mod writes recent_players.txt: "<ROOM>\t<name>" per line)
static std::wstring played_with(const std::wstring& code) {
    if (code.empty()) return L"";
    std::vector<std::wstring> names;
    for (auto& ch : g_ch) {
        if (ch.dir.empty()) continue;
        std::string data;
        if (!read_file(bin_dir(ch) + L"\\ue4ss\\Mods\\PoppyCoop\\recent_players.txt", data)) continue;
        size_t p = 0;
        while (p < data.size()) {
            size_t e = data.find('\n', p);
            if (e == std::string::npos) e = data.size();
            std::string line = data.substr(p, e - p);
            p = e + 1;
            size_t t = line.find('\t');
            if (t == std::string::npos) continue;
            std::wstring room(line.begin(), line.begin() + t), name;
            for (char c : line.substr(t + 1)) if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '-') name += (wchar_t)c;
            for (auto& c : room) c = towupper(c);
            if (room != code || name.empty()) continue;
            bool dup = false;
            for (auto& n : names) if (n == name) dup = true;
            if (!dup) names.push_back(name);
        }
    }
    std::wstring r;
    for (size_t i = 0; i < names.size() && i < 6; i++) r += (i ? L", " : L"") + names[i];
    return r;
}

// the last room codes joined (ini [Launcher] Recent = "ABC123,XYZ789,..."), newest first
static std::vector<std::wstring> recent_codes() {
    std::vector<std::wstring> v;
    std::wstring s = ini_get(L"Launcher", L"Recent"), cur;
    for (wchar_t ch : s + L",") {
        if (ch == L',') { if (!cur.empty() && v.size() < 4) v.push_back(cur); cur.clear(); }
        else cur += ch;
    }
    return v;
}
static void remember_code(const std::wstring& code) {
    if (code.empty()) return;
    std::wstring s = code;
    for (auto& c : recent_codes()) if (c != code) s += L"," + c;
    ini_set(L"Launcher", L"Recent", s);
}

static void launch_now(int idx) {
    Chapter& c = g_ch[idx];
    if (g_prof.tab == 2) remember_code(g_prof.join_code);
    if (!write_mod_settings(c, g_prof)) { toast(tr(L"Couldn't save the mod settings - try running the launcher as administrator.")); return; }
    archive_logs(c);
    if (!launch_game(c)) { toast(tr(L"Couldn't start the game.")); return; }
    g_starting_ch = idx; g_starting_t0 = GetTickCount64();
    toast(via_steam(c) ? tr(L"Starting Poppy Playtime - Steam may take a few seconds") : tr(L"Starting Poppy Playtime..."));
}

// "Several games at once": window N gets "<name>_N" and the next figure colour, same room
static void launch_another(int idx) {
    Chapter& c = g_ch[idx];
    int n = std::max(1, running_count(c));
    static const wchar_t* ORDER[] = { L"yellow", L"orange", L"pink", L"purple", L"green", L"teal", L"blue" };   // the mod's order
    int ci = 0;
    for (int i = 0; i < 7; i++) if (g_prof.color == ORDER[i]) ci = i;
    std::wstring nm = clean_name(g_prof.name);
    if (nm.empty()) nm = L"Player";
    nm = nm.substr(0, 20) + L"_" + std::to_wstring(n + 1);
    if (!launch_game(c, n, nm, ORDER[(ci + n) % 7], room_for(g_prof))) { toast(tr(L"Couldn't start the game.")); return; }
    toast(tr(L"Started game window ") + std::to_wstring(n + 1) + L" (" + nm + L")");
}

static void do_play() {
    Chapter& c = cur();
    g_focus = {};
    if (game_running(c)) {
        if (!g_multi) { toast(tr(L"The game is already running - close it to switch rooms.")); return; }
        if (inst_ver(c) != MOD_VERSION) { toast(tr(L"Close the open games first so the mod can be updated.")); return; }
        launch_another(g_sel);
        return;
    }
    if (g_prof.tab == 2 && extract_code(g_prof.join_code).empty()) { toast(tr(L"Type your friend's room code first.")); g_focus = { &g_prof.join_code, 12, true }; return; }
    if (g_prof.tab == 2) g_prof.join_code = extract_code(g_prof.join_code);
    save_profile();
    if (inst_ver(c) != MOD_VERSION) { start_install(g_sel, true); return; }
    launch_now(g_sel);
}

// ------------------------------------------------------------------ invite handling
static void open_invite(const std::wstring& arg) {
    if (lower(arg).find(L"poppycoop://") == std::wstring::npos) return;
    std::wstring code = extract_code(arg);
    if (code.empty()) return;
    g_prof.join_code = code; g_prof.tab = 2; g_page = Page::Chapter;
    save_profile();
    toast(tr(L"Invite opened - room ") + code + tr(L". Pick the chapter and press PLAY!"));
}

// ------------------------------------------------------------------ window
static bool g_test = false;
static void test_tick(HWND h);
static LRESULT CALLBACK wndproc(HWND h, UINT m, WPARAM wp, LPARAM lp) {
    switch (m) {
    case WM_PAINT: {
        PAINTSTRUCT ps; HDC dc = BeginPaint(h, &ps);
        RECT rc; GetClientRect(h, &rc);
        paint(dc, rc.right, rc.bottom);
        EndPaint(h, &ps);
        return 0;
    }
    case WM_ERASEBKGND: return 1;
    case WM_SYSCOMMAND:
        if (g_own_bar) {
            UINT sc = (UINT)(wp & 0xFFF0);
            if (sc == SC_MAXIMIZE && !IsZoomed(h)) GetWindowRect(h, &g_normal_rect);
            if (sc == SC_RESTORE && IsZoomed(h) && g_normal_rect.right > g_normal_rect.left) {
                ShowWindow(h, SW_RESTORE);
                RECT n = g_normal_rect;
                SetWindowPos(h, nullptr, n.left, n.top, n.right - n.left, n.bottom - n.top, SWP_NOZORDER | SWP_NOACTIVATE);
                return 0;
            }
        }
        break;
    case WM_NCCALCSIZE:
        if (g_own_bar && wp) return 0;             // the whole window is client area - no Wine caption
        break;
    case WM_NCPAINT:
        if (g_own_bar) return 0;
        break;
    case WM_NCACTIVATE:
        if (g_own_bar) { InvalidateRect(h, nullptr, FALSE); return TRUE; }
        break;
    case WM_NCHITTEST:
        if (g_own_bar) {
            POINT p = { GET_X_LPARAM(lp), GET_Y_LPARAM(lp) };
            ScreenToClient(h, &p);
            RECT rc; GetClientRect(h, &rc);
            const int e = (int)(RESIZE_EDGE * g_dpi + 0.5), tb = bar_h();
            if (!IsZoomed(h)) {
                bool l = p.x < e, r = p.x >= rc.right - e, t = p.y < e, b = p.y >= rc.bottom - e;
                if (t && l) return HTTOPLEFT;
                if (t && r) return HTTOPRIGHT;
                if (b && l) return HTBOTTOMLEFT;
                if (b && r) return HTBOTTOMRIGHT;
                if (l) return HTLEFT;
                if (r) return HTRIGHT;
                if (t) return HTTOP;
                if (b) return HTBOTTOM;
            }
            if (p.y < tb && p.x < rc.right - 3 * (int)(TITLE_BTN_W * g_dpi + 0.5)) return HTCAPTION;
            return HTCLIENT;
        }
        break;
    case WM_GETMINMAXINFO: {
        RECT r = { 0, 0, (int)(MIN_W * g_dpi + 0.5), (int)(MIN_H * g_dpi + 0.5) };
        adjust_window_rect(r, (DWORD)GetWindowLongW(h, GWL_STYLE));
        auto* mm = (MINMAXINFO*)lp;
        mm->ptMinTrackSize = { r.right - r.left, r.bottom - r.top };
        return 0;
    }
    case WM_SIZE: {
        // a window manager that ignores the minimum (some Linux desktops): snap back to it
        if (wp != SIZE_MINIMIZED && wp != SIZE_MAXIMIZED &&
            (LOWORD(lp) < (int)(MIN_W * g_dpi) - 1 || HIWORD(lp) < (int)(MIN_H * g_dpi) - 1))
            SetTimer(h, TIMER_MINSIZE, 300, nullptr);   // re-checked after the mouse is let go (WM ignores it while dragging)
        InvalidateRect(h, nullptr, FALSE);
        return 0;
    }
    case WM_APP_MINSIZE: {
        RECT cr; GetClientRect(h, &cr);
        if (IsIconic(h) || IsZoomed(h) || (cr.right >= (int)(MIN_W * g_dpi) - 1 && cr.bottom >= (int)(MIN_H * g_dpi) - 1)) {
            KillTimer(h, TIMER_MINSIZE); return 0;
        }
        RECT r = { 0, 0, std::max((int)cr.right, (int)(MIN_W * g_dpi + 0.5)), std::max((int)cr.bottom, (int)(MIN_H * g_dpi + 0.5)) };
        adjust_window_rect(r, (DWORD)GetWindowLongW(h, GWL_STYLE));
        SetWindowPos(h, nullptr, 0, 0, r.right - r.left, r.bottom - r.top, SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
        return 0;
    }
    case WM_EXITSIZEMOVE: save_window_size(); return 0;
    case WM_MOUSEMOVE: {
        g_mouse = { GET_X_LPARAM(lp), GET_Y_LPARAM(lp) - bar_h() };
        if (g_log_drag) log_drag_to(g_mouse.y);
        TRACKMOUSEEVENT t = { sizeof(t), TME_LEAVE, h, 0 }; TrackMouseEvent(&t);
        InvalidateRect(h, nullptr, FALSE);
        return 0;
    }
    case WM_MOUSELEAVE: g_mouse = { -1, -1 }; InvalidateRect(h, nullptr, FALSE); return 0;
    case WM_SETCURSOR:
        if (LOWORD(lp) == HTCLIENT) {
            for (auto& hit : g_hits) if (hit.hand && hover(hit.r)) { SetCursor(LoadCursor(nullptr, IDC_HAND)); return TRUE; }
            SetCursor(LoadCursor(nullptr, IDC_ARROW)); return TRUE;
        }
        break;
    case WM_LBUTTONDOWN: {
        g_mouse = { GET_X_LPARAM(lp), GET_Y_LPARAM(lp) - bar_h() };
        if (g_page == Page::Logs && g_log_track.bottom > g_log_track.top && PtInRect(&g_log_track, g_mouse)) {
            bool on_thumb = g_mouse.y >= g_log_thumb_top && g_mouse.y < g_log_thumb_top + g_log_thumb_h;
            g_log_grab = on_thumb ? g_mouse.y - g_log_thumb_top : g_log_thumb_h / 2;   // bar outside the thumb: jump there
            g_log_drag = true;
            log_drag_to(g_mouse.y);
            SetCapture(h);
            InvalidateRect(h, nullptr, FALSE);
            return 0;
        }
        g_pressed = -1;
        for (int i = (int)g_hits.size() - 1; i >= 0; i--) if (hover(g_hits[i].r)) { g_pressed = i; break; }
        if (g_pressed < 0) { g_focus = {}; g_capture = -1; }
        SetCapture(h);
        InvalidateRect(h, nullptr, FALSE);
        return 0;
    }
    case WM_LBUTTONUP: {
        ReleaseCapture();
        if (g_log_drag) { g_log_drag = false; g_pressed = -1; InvalidateRect(h, nullptr, FALSE); return 0; }
        g_mouse = { GET_X_LPARAM(lp), GET_Y_LPARAM(lp) - bar_h() };
        if (g_pressed >= 0 && g_pressed < (int)g_hits.size() && hover(g_hits[g_pressed].r)) {
            auto fn = g_hits[g_pressed].fn;   // copy: the handler may change the page
            fn();
        }
        g_pressed = -1;
        InvalidateRect(h, nullptr, FALSE);
        return 0;
    }
    case WM_MOUSEWHEEL:
        if (g_page == Page::News) {
            POINT p = { GET_X_LPARAM(lp), GET_Y_LPARAM(lp) };
            ScreenToClient(h, &p);
            p.y -= bar_h();
            int notches = GET_WHEEL_DELTA_WPARAM(wp) / WHEEL_DELTA;
            if (!notches) notches = GET_WHEEL_DELTA_WPARAM(wp) < 0 ? -1 : 1;
            if (PtInRect(&g_news_view, p)) g_news_scroll = std::max(0, std::min(g_news_max, g_news_scroll - notches * 40));
            else news_select(g_news_sel - notches);
            InvalidateRect(h, nullptr, FALSE);
            return 0;
        }
        if (g_page == Page::Logs && !g_logs.empty()) {
            POINT p = { GET_X_LPARAM(lp), GET_Y_LPARAM(lp) };
            ScreenToClient(h, &p);
            p.y -= bar_h();
            int notches = GET_WHEEL_DELTA_WPARAM(wp) / WHEEL_DELTA;
            if (!notches) notches = GET_WHEEL_DELTA_WPARAM(wp) < 0 ? -1 : 1;
            if (PtInRect(&g_log_view, p)) log_scroll(notches * 3);     // over the log: 3 lines per notch
            else log_select(std::max(0, std::min((int)g_logs.size() - 1, g_log_sel - notches)));
            InvalidateRect(h, nullptr, FALSE);
        }
        return 0;
    case WM_KEYDOWN: case WM_SYSKEYDOWN:
        if (g_capture >= 0) { set_key((UINT)wp); InvalidateRect(h, nullptr, FALSE); return 0; }
        if (g_page == Page::News && (wp == VK_UP || wp == VK_DOWN)) {
            news_select(g_news_sel + (wp == VK_DOWN ? 1 : -1));
            InvalidateRect(h, nullptr, FALSE);
            return 0;
        }
        if (g_page == Page::Logs && !g_logs.empty() && (wp == VK_UP || wp == VK_DOWN)) {
            log_select(std::max(0, std::min((int)g_logs.size() - 1, g_log_sel + (wp == VK_DOWN ? 1 : -1))));
            InvalidateRect(h, nullptr, FALSE); return 0;
        }
        if (g_page == Page::Logs && !g_logs.empty() && (wp == VK_PRIOR || wp == VK_NEXT || wp == VK_HOME || wp == VK_END)) {
            const int ALL = 1 << 30;
            log_scroll(wp == VK_PRIOR ? g_log_page - 1 : wp == VK_NEXT ? -(g_log_page - 1) : wp == VK_HOME ? ALL : -ALL);
            InvalidateRect(h, nullptr, FALSE); return 0;
        }
        if (g_focus.value && wp == 'V' && (GetKeyState(VK_CONTROL) & 0x8000)) {
            std::wstring t = clipboard_text();
            if (g_focus.code) t = extract_code(t);
            for (wchar_t ch : t) if (g_focus.value->size() < g_focus.max && ch >= 32) *g_focus.value += g_focus.code ? (wchar_t)towupper(ch) : ch;
            InvalidateRect(h, nullptr, FALSE);
            return 0;
        }
        if (g_focus.value && wp == VK_RETURN) {
            if (g_focus.value == &g_prof.join_code) do_play();
            g_focus = {}; InvalidateRect(h, nullptr, FALSE); return 0;
        }
        if (g_focus.value && wp == VK_ESCAPE) { g_focus = {}; InvalidateRect(h, nullptr, FALSE); return 0; }
        break;
    case WM_CHAR:
        if (g_focus.value && g_capture < 0) {
            wchar_t ch = (wchar_t)wp;
            std::wstring& v = *g_focus.value;
            if (ch == 8) { if (!v.empty()) v.pop_back(); }
            else if (ch >= 32 && ch != 127 && v.size() < g_focus.max && !(GetKeyState(VK_CONTROL) & 0x8000)) {
                if (g_focus.code) { if (iswalnum(ch) && ch < 128) v += (wchar_t)towupper(ch); }
                else if (g_focus.value == &g_new_addr) { if (ch > 32 && ch < 127) v += ch; }   // server address: URL / IP
                else if (g_focus.value == &g_friend_edit) { if ((iswalnum(ch) && ch < 128) || ch == L'_' || ch == L'-' || ch == L'#') v += ch; }
                else if ((iswalnum(ch) && ch < 128) || ch == L'_' || ch == L'-' || ch == L' ') v += ch;
            }
            if (g_focus.value == &g_prof.join_code || g_focus.value == &g_prof.name) save_profile();
            g_caret_on = true;
            InvalidateRect(h, nullptr, FALSE);
            return 0;
        }
        break;
    case WM_TIMER:
        if (wp == TIMER_MINSIZE) { SendMessageW(h, WM_APP_MINSIZE, 0, 0); return 0; }
        if (wp == TIMER_ANIM) { InvalidateRect(h, nullptr, FALSE); return 0; }
        if (wp == TIMER_SPLIT) { if (g_split_on) keep_game_windows(); return 0; }
        if (wp == TIMER_PROBE) { start_probe(g_page == Page::Servers); return 0; }
        if (wp == TIMER_CARET) { if (g_focus.value) { g_caret_on = !g_caret_on; InvalidateRect(h, nullptr, FALSE); } return 0; }
        if (wp == TIMER_POLL) {
            if (g_test) test_tick(h);
            bool changed = false;
            for (size_t i = 0; i < g_ch.size() && i < 8; i++) {
                bool r = game_running(g_ch[i]);
                if (r != g_running[i]) {
                    if (!r) { g_crash_check_at = GetTickCount64() + 10000; archive_logs(g_ch[i]); }   // the crash reporter writes its folder after the exit
                    g_running[i] = r; changed = true;
                }
            }
            {   // Discord Rich Presence while a chapter runs (only with a DiscordAppId in launcher.ini)
                static DiscordRP rp;
                static std::wstring appid = ini_get(L"Launcher", L"DiscordAppId", L"");
                int playing = 0;
                for (size_t i = 0; i < g_ch.size() && i < 8; i++) if (g_running[i]) playing = g_ch[i].num;
                rp.update(appid, playing);
            }
            if (g_starting_ch >= 0) {
                if (g_running[g_starting_ch]) {
                    toast(tr(L"Have fun! F6 = go to a friend, T = ping a spot."));
                    g_starting_ch = -1;
                } else if (GetTickCount64() - g_starting_t0 > 45000) {
                    toast(tr(L"The game didn't open yet - check Steam."));
                    g_starting_ch = -1;
                }
                changed = true;
            }
            ULONGLONG nw = GetTickCount64();
            if (g_crash_check_at && nw > g_crash_check_at) { g_crash_check_at = 0; maybe_report_crashes(); }
            poll_settings_offer();
            restart_tick();
            // friends: status heartbeat + list every 60 s (only once the player has opened the friends page);
            // the list every 15 s while the page is open
            // (a game started / ended: say so right away, so friends see the room code at once)
            static int was_playing = -1;
            int playing = 0;
            for (size_t i = 0; i < g_ch.size() && i < 8; i++) if (g_running[i]) playing = 1;
            bool status_changed = was_playing >= 0 && playing != was_playing && g_fnet_state == 1;
            if (!g_fnet_busy) was_playing = playing;
            bool any_online = false;
            for (auto& f : g_fnet.friends) if (f.online) any_online = true;
            if (FEATURE_ONLINE && friends_used() && !g_fnet_busy && (status_changed || nw - g_fnet_hello_at > (g_fnet_state == 2 ? 300000ULL : 30000ULL))) friends_net_sync(true);
            else if ((g_page == Page::Friends || any_online) && !g_fnet_busy && g_fnet_state == 1 && nw - g_fnet_hello_at > 10000) {
                static ULONGLONG list_at = 0;
                if (nw - list_at > 10000) { list_at = nw; friends_net_sync(false); }
            }
            if (!g_toast.empty() && nw > g_toast_until + 1500) g_toast.clear();   // after its fade-out
            if (changed || (!g_toast.empty() && nw > g_toast_until)) InvalidateRect(h, nullptr, FALSE);
            return 0;
        }
        break;
    case WM_APP_PROGRESS: g_install_pct = (int)wp; InvalidateRect(h, nullptr, FALSE); return 0;
    case WM_APP_INSTALLED: {
        g_installing = false;
        int idx = g_install_ch;
        iv_reset();
        if (wp && idx >= 0) { ini_set(sec_name(g_ch[idx]).c_str(), L"SetupDone", L"1"); g_setup_done[(g_ch[idx].num - 1) & 7] = 1; }
        if (!wp) { toast(tr(L"Install failed - close the game, or run the launcher as administrator.")); g_launch_after_install = false; }
        else {
            toast(L"Co-op mod v" MOD_VERSION L" installed.");
            if (g_launch_after_install && idx >= 0) launch_now(idx);
        }
        g_launch_after_install = false;
        InvalidateRect(h, nullptr, FALSE);
        return 0;
    }
    case WM_APP_SELFUPD: {
        std::wstring* r = (std::wstring*)lp;
        std::wstring exe = r ? *r : L"";
        delete r;
        g_updating = false;
        if (exe.empty()) {
            toast(tr(L"Automatic update failed - opening the download page."));
            ShellExecuteW(nullptr, L"open", RELEASES_PAGE, nullptr, nullptr, SW_SHOWNORMAL);
        } else {
            save_profile();
            ShellExecuteW(nullptr, L"open", exe.c_str(), L"--after-update", nullptr, SW_SHOWNORMAL);
            DestroyWindow(h);
        }
        InvalidateRect(h, nullptr, FALSE);
        return 0;
    }
    case WM_APP_FRIENDS: {
        FriendsResult* r = (FriendsResult*)lp;
        if (r) { on_friends_result(r); delete r; }
        InvalidateRect(h, nullptr, FALSE);
        return 0;
    }
    case WM_APP_CRASHSENT:
        toast(wp ? tr(L"The game crashed - a crash report was sent to the developers. Thanks!")
                 : tr(L"The game crashed - sending the crash report failed. \"Report a problem\" makes a zip for us."));
        return 0;
    case WM_APP_UPDATE: {
        std::wstring* t = (std::wstring*)lp;
        if (t) { g_latest = *t; delete t; }
        maybe_auto_update();
        InvalidateRect(h, nullptr, FALSE);
        return 0;
    }
    case WM_APP_PROBE: {
        if (lp) {
            ProbeResult* r = (ProbeResult*)lp;
            bool found = false;
            for (auto& p : g_probes) if (p.first == r->key) { p.second = r->p; found = true; }
            if (!found) g_probes.push_back({ r->key, r->p });
            delete r;
        }
        InvalidateRect(h, nullptr, FALSE);
        return 0;
    }
    case WM_COPYDATA: {
        COPYDATASTRUCT* cd = (COPYDATASTRUCT*)lp;
        if (cd && cd->lpData && cd->cbData >= 2) open_invite(std::wstring((const wchar_t*)cd->lpData, cd->cbData / 2));
        if (IsIconic(h)) ShowWindow(h, SW_RESTORE);
        SetForegroundWindow(h);
        InvalidateRect(h, nullptr, FALSE);
        return TRUE;
    }
    case WM_DESTROY: save_window_size(); save_profile(); PostQuitMessage(0); return 0;
    }
    return DefWindowProcW(h, m, wp, lp);
}

// Developer test hook (POPPYCOOP_LAUNCHER_TEST=1): reads launcher_test.txt next to the exe once a second and
// replays it - "click X Y" (client coordinates at 96 dpi), "key VK", "type TEXT", "close". Off for normal players.
static void test_tick(HWND h) {
    wchar_t exe[MAX_PATH];
    GetModuleFileNameW(nullptr, exe, MAX_PATH);
    std::wstring f = parent(exe) + L"\\launcher_test.txt";
    std::string cmds;
    if (!read_file(f, cmds)) return;
    DeleteFileW(f.c_str());
    size_t p = 0;
    while (p < cmds.size()) {
        size_t e = cmds.find('\n', p);
        std::string line = cmds.substr(p, e == std::string::npos ? std::string::npos : e - p);
        p = e == std::string::npos ? cmds.size() : e + 1;
        int x = 0, y = 0;
        if (sscanf(line.c_str(), "click %d %d", &x, &y) == 2) {
            LPARAM lp = MAKELPARAM(S(x), S(y));
            SendMessageW(h, WM_MOUSEMOVE, 0, lp);
            UpdateWindow(h);
            RECT rc; GetClientRect(h, &rc);
            HDC dc = GetDC(h); paint(dc, rc.right, rc.bottom); ReleaseDC(h, dc);   // rebuild click areas
            SendMessageW(h, WM_LBUTTONDOWN, MK_LBUTTON, lp);
            SendMessageW(h, WM_LBUTTONUP, 0, lp);
        } else if (sscanf(line.c_str(), "key %d", &x) == 1) {
            SendMessageW(h, WM_KEYDOWN, (WPARAM)x, 0);
        } else if (line.rfind("close", 0) == 0) {
            PostMessageW(h, WM_CLOSE, 0, 0);
        } else if (line.rfind("type ", 0) == 0) {
            for (wchar_t ch : wide(line.substr(5))) if (ch != L'\r') SendMessageW(h, WM_CHAR, ch, 0);
        }
    }
}


// ------------------------------------------------------------------ command line (Nucleus Co-op handlers, scripts)
// PoppyCoopLauncher.exe --play --chapter N [--name X] [--color C] [--room CODE] [--dir "game folder"] [--multi]
// starts the game without showing the launcher; errors go to %APPDATA%\PoppyCoop\cli_last_error.txt
static std::wstring cli_value(const std::vector<std::wstring>& a, const wchar_t* key) {
    for (size_t i = 0; i + 1 < a.size(); i++) if (lower(a[i]) == key) return a[i + 1];
    return L"";
}
static int cli_fail(const std::wstring& msg) {
    std::wstring dir = env(L"APPDATA") + L"\\PoppyCoop";
    write_text(dir + L"\\cli_last_error.txt", msg + L"\n");
    return 1;
}
static int cli_play(const std::wstring& cmdline) {
    std::vector<std::wstring> a;
    int n = 0;
    LPWSTR* av = CommandLineToArgvW(cmdline.c_str(), &n);
    for (int i = 0; av && i < n; i++) a.push_back(av[i]);
    if (av) LocalFree(av);
    bool multi = false;
    for (auto& x : a) if (lower(x) == L"--multi") multi = true;
    ini_init();
    g_experimental = true;                 // a handler asking for Chapter 3-5 means it
    chapters_init();
    int num = _wtoi(cli_value(a, L"--chapter").c_str());
    if (num <= 0) num = _wtoi(ini_get(L"Launcher", L"Chapter", L"1").c_str());
    if (num < 1 || num > (int)g_ch.size()) return cli_fail(L"unknown chapter " + std::to_wstring(num));
    Chapter& c = g_ch[num - 1];
    chapter_load(c);
    std::wstring d = cli_value(a, L"--dir");
    if (!d.empty()) { c.dir = normalize_dir(c, d); bind_dir(c); c.state = check_dir(c, c.dir); }
    if (!dir_usable(c.state)) return cli_fail(L"Chapter " + std::to_wstring(num) + L" not found in '" + c.dir + L"' - use --dir or set it up in the launcher");
    Profile p;
    p.name = clean_name(ini_get(L"Launcher", L"Name"));
    p.color = ini_get(L"Launcher", L"Color", L"yellow");
    p.code = upper(ini_get(L"Launcher", L"Code"));
    p.join_code = upper(ini_get(L"Launcher", L"JoinCode"));
    p.tab = _wtoi(ini_get(L"Launcher", L"Tab", L"0").c_str());
    load_servers(); apply_server();
    p.srv_mode = g_prof.srv_mode; p.srv_addr = g_prof.srv_addr; p.srv_port = g_prof.srv_port;
    std::wstring v;
    if (!(v = clean_name(cli_value(a, L"--name"))).empty()) p.name = v;
    if (!(v = lower(cli_value(a, L"--color"))).empty()) p.color = v;
    if (!(v = cli_value(a, L"--room")).empty()) { if (lower(v) == L"public") p.tab = 0; else { p.tab = 2; p.join_code = upper(v); } }
    if (p.name.empty()) p.name = L"Player";
    int window = running_count(c);
    if (window > 0 && !multi) return cli_fail(L"the game is already running (add --multi for another window)");
    if (inst_ver(c) != MOD_VERSION) {
        if (window > 0) return cli_fail(L"mod needs an update - close the running games first");
        if (!install_files(c, p, nullptr)) return cli_fail(L"couldn't install the mod into " + bin_dir(c));
    } else if (window == 0 && !write_mod_settings(c, p)) return cli_fail(L"couldn't write the mod settings into " + mod_dir(c));
    bool ok = window > 0 ? launch_game(c, window, p.name, p.color, room_for(p))
                         : launch_game(c, 0, cli_value(a, L"--name").empty() ? L"" : p.name, cli_value(a, L"--color").empty() ? L"" : p.color,
                                       cli_value(a, L"--room").empty() ? L"" : room_for(p));
    if (!ok) return cli_fail(L"couldn't start " + c.dir + L"\\" + c.exe);
    DeleteFileW((env(L"APPDATA") + L"\\PoppyCoop\\cli_last_error.txt").c_str());
    return 0;
}

int WINAPI wWinMain(HINSTANCE inst, HINSTANCE, PWSTR cmd, int show) {
    if (cmd && std::wstring(cmd).find(L"--play") != std::wstring::npos) return cli_play(GetCommandLineW());
    std::wstring arg = cmd ? cmd : L"";
    bool after_update = arg.find(L"--after-update") != std::wstring::npos;
    if (after_update) arg.clear();
    {   // left over from a self-update
        wchar_t self[MAX_PATH];
        if (GetModuleFileNameW(nullptr, self, MAX_PATH)) DeleteFileW((std::wstring(self) + L".old").c_str());
    }
    // one launcher at a time: hand an invite link to the running one
    HANDLE mtx = CreateMutexW(nullptr, TRUE, L"PoppyCoopLauncherSingleInstance");
    for (int i = 0; after_update && mtx && GetLastError() == ERROR_ALREADY_EXISTS && i < 50; i++) {
        CloseHandle(mtx);          // the old launcher is still closing
        Sleep(100);
        mtx = CreateMutexW(nullptr, TRUE, L"PoppyCoopLauncherSingleInstance");
    }
    if (GetLastError() == ERROR_ALREADY_EXISTS) {
        HWND other = FindWindowW(L"PoppyCoopLauncher3", nullptr);
        if (other) {
            COPYDATASTRUCT cd = { 1, (DWORD)((arg.size() + 1) * 2), (void*)arg.c_str() };
            SendMessageW(other, WM_COPYDATA, 0, (LPARAM)&cd);
            SetForegroundWindow(other);
        }
        return 0;
    }
    // sharp text on high-DPI screens
    HMODULE u32 = GetModuleHandleW(L"user32.dll");
    auto ctx = (BOOL(WINAPI*)(HANDLE))GetProcAddress(u32, "SetProcessDpiAwarenessContext");
    if (!ctx || !ctx((HANDLE)-4)) SetProcessDPIAware();
    CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    HDC sdc = GetDC(nullptr);
    g_dpi = GetDeviceCaps(sdc, LOGPIXELSX) / 96.0;
    ReleaseDC(nullptr, sdc);
    if (g_dpi < 1.0) g_dpi = 1.0;
    g_s = g_dpi;

    ini_init();
    g_experimental = ini_get(L"Launcher", L"Experimental", L"0") == L"1";
    g_multi = ini_get(L"Launcher", L"Multi", L"0") == L"1";
    g_split_layout = std::max(0, std::min(SPLIT_LAYOUTS - 1, _wtoi(ini_get(L"Launcher", L"SplitLayout", L"1").c_str())));
    g_split_on = g_multi && g_split_layout > 0;
    g_coop_always = ini_get(L"Launcher", L"CoopAlways", L"0") == L"1";
    g_autoupd = ini_get(L"Launcher", L"AutoUpdate", L"1") != L"0";
    friends_load();
    {
        std::wstring cr = ini_get(L"Launcher", L"CrashReports", L"");
        g_crashrep = cr.empty() ? -1 : (cr == L"1" ? 1 : 0);
    }
    chapters_init();
    for (auto& c : g_ch) chapter_load(c);
    g_prof.name = clean_name(ini_get(L"Launcher", L"Name"));
    g_prof.color = ini_get(L"Launcher", L"Color", L"yellow");
    g_prof.code = upper(ini_get(L"Launcher", L"Code"));
    g_prof.join_code = upper(ini_get(L"Launcher", L"JoinCode"));
    g_prof.tab = _wtoi(ini_get(L"Launcher", L"Tab", L"0").c_str());
    if (g_prof.tab < 0 || g_prof.tab > 2) g_prof.tab = 0;
    g_sel = _wtoi(ini_get(L"Launcher", L"Chapter", L"1").c_str()) - 1;
    if (g_sel < 0 || g_sel >= (int)g_ch.size() || !playable(g_ch[g_sel])) g_sel = 0;
    {
        bool any = false;
        for (auto& c : g_ch) if (playable(c) && !inst_ver(c).empty()) any = true;
        if (!any && ini_get(L"Launcher", L"Chapter").empty()) g_page = Page::Welcome;
    }
    {
        wchar_t tv[8] = {};
        g_test = GetEnvironmentVariableW(L"POPPYCOOP_LAUNCHER_TEST", tv, 8) > 0 && tv[0] == L'1';
    }
    register_protocol();
    g_theme = ini_get(L"Launcher", L"Theme", L"dark");
    {   // language: saved choice, else the Windows UI language (German -> Deutsch)
        std::wstring lg = ini_get(L"Launcher", L"Lang");
        if (lg == L"de") g_lang = 1;
        else if (lg.empty() && PRIMARYLANGID(GetUserDefaultUILanguage()) == LANG_GERMAN) g_lang = 1;
    }
    g_accent_pref = ini_get(L"Launcher", L"Accent", L"figure");
    g_anims = ini_get(L"Launcher", L"Animations", L"1") != L"0";
    apply_theme();
    make_fonts();
    load_servers();
    apply_server();
    g_lan = lan_ips();

    WNDCLASSEXW wc = { sizeof(wc) };
    wc.lpfnWndProc = wndproc;
    wc.hInstance = inst;
    wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
    wc.hIcon = LoadIconW(inst, MAKEINTRESOURCEW(1));
    wc.hIconSm = wc.hIcon;
    wc.lpszClassName = L"PoppyCoopLauncher3";
    RegisterClassExW(&wc);
    {   // own title bar under Proton (see g_own_bar)
        std::wstring ob = ini_get(L"Launcher", L"OwnTitleBar", L"");
        wchar_t ev[8];
        bool proton = GetEnvironmentVariableW(L"STEAM_COMPAT_PROTON", ev, 8) > 0 || GetEnvironmentVariableW(L"STEAM_COMPAT_DATA_PATH", nullptr, 0) > 0;
        g_own_bar = ob == L"1" || (ob != L"0" && running_on_wine() && proton);
    }
    DWORD style = WS_OVERLAPPEDWINDOW;             // resizable + maximize; size is remembered
    RECT work; SystemParametersInfoW(SPI_GETWORKAREA, 0, &work, 0);
    int ww = _wtoi(ini_get(L"Launcher", L"WinW", L"0").c_str()), wh = _wtoi(ini_get(L"Launcher", L"WinH", L"0").c_str());
    RECT r = { 0, 0, S(BASE_W), S(BASE_H) };
    adjust_window_rect(r, style);
    if (ww <= 0 || wh <= 0) { ww = (int)((r.right - r.left) / g_dpi); wh = (int)((r.bottom - r.top) / g_dpi); }   // first start: 1180x780 inside
    ww = std::min((int)(ww * g_dpi), (int)(work.right - work.left)); wh = std::min((int)(wh * g_dpi), (int)(work.bottom - work.top));
    g_wnd = CreateWindowExW(0, wc.lpszClassName, L"Poppy Playtime Co-op", style, CW_USEDEFAULT, CW_USEDEFAULT,
                            ww, wh, nullptr, nullptr, inst, nullptr);
    if (g_own_bar) SetWindowPos(g_wnd, nullptr, 0, 0, 0, 0, SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
    if (ini_get(L"Launcher", L"WinMax", L"0") == L"1" && show != SW_SHOWMINIMIZED && show != SW_SHOWMINNOACTIVE) show = SW_SHOWMAXIMIZED;
    // dark title bar (Windows 10 20H1+ / 11); ignored elsewhere
    if (HMODULE dwm = LoadLibraryW(L"dwmapi.dll")) {
        auto set = (HRESULT(WINAPI*)(HWND, DWORD, LPCVOID, DWORD))GetProcAddress(dwm, "DwmSetWindowAttribute");
        BOOL on = TRUE;
        if (set) set(g_wnd, 20, &on, sizeof(on));
    }
    for (size_t i = 0; i < g_ch.size() && i < 8; i++) g_running[i] = game_running(g_ch[i]);
    open_invite(arg);
    if (env(L"POPPYCOOP_LAUNCHER_TEST") == L"1") {          // test: open a page directly (screenshots)
        std::wstring pg = env(L"POPPYCOOP_LAUNCHER_PAGE");
        if (pg == L"news") g_page = Page::News;
        else if (pg == L"friends") { g_page = Page::Friends; friends_refresh(); g_friends_on = 1; friends_net_sync(true); }
        else if (pg == L"servers") g_page = Page::Servers;
    }
    ShowWindow(g_wnd, show);
    UpdateWindow(g_wnd);
    if (after_update) toast(tr(L"Updated to v") + MOD_VERSION);
    if (!g_test) maybe_report_crashes();
    SetTimer(g_wnd, TIMER_POLL, 1000, nullptr);
    SetTimer(g_wnd, TIMER_SPLIT, 250, nullptr);       // split screen: keep the game windows in place
    SetTimer(g_wnd, TIMER_CARET, 530, nullptr);
    start_probe(false);
    SetTimer(g_wnd, TIMER_PROBE, 30000, nullptr);
    std::thread([w = g_wnd] {                      // update check (once per start)
        std::wstring* t = new std::wstring(latest_release());
        if (!PostMessageW(w, WM_APP_UPDATE, 0, (LPARAM)t)) delete t;
    }).detach();

    MSG msg;
    while (GetMessageW(&msg, nullptr, 0, 0)) { TranslateMessage(&msg); DispatchMessageW(&msg); }
    if (mtx) CloseHandle(mtx);
    return 0;
}
