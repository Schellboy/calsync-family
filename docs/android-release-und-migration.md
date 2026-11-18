# Android-Release und Migration auf dem Xiaomi 14T

## Vor der ersten Installation

Lass die bestehende Debug-App samt Daten auf dem Xiaomi installiert. Deinstalliere sie nicht und lösche ihre App-Daten nicht. Eine mit einem neuen Schlüssel signierte APK mit derselben Paketkennung `de.schellboy.calsyncfamily` kann Android nicht als Update der Debug-App installieren. Der Wechsel per Deinstallation entfernt den privaten App-Speicher. Die Google-Termine sind davon getrennt. Ohne die lokalen Zuordnungen kann die neue App vorhandene Kopien jedoch erneut anlegen oder bestehende Änderungen nicht mehr korrekt zuordnen.

### Was sich heute sichern und übertragen lässt

- Die SQLite-Datei `calendar_sync.db` enthält die Profile mit ihren stabilen IDs, die Zuordnungen zu Zielterminen einschließlich einzelner Serienvorkommen, die Liste der von der App erstellten Termine und den Statusverlauf. Die Datenbank arbeitet mit einem WAL. Eine einzelne Kopie der Hauptdatei während des Betriebs ist daher kein verlässliches Backup. Geräteeinstellungen und der Marker für die alte Profilmigration liegen separat in SharedPreferences.
- Die App hat derzeit keinen Export oder Import für Profile oder Zuordnungen. Ein Google-Kalender-Export und das manuelle Nachbauen der beiden Profile stellen diese Daten nicht wieder her. Android- oder Xiaomi-Backups sind für den Wechsel der Signatur kein nachgewiesener Wiederherstellungsweg.
- Eine Debug-Installation kann auf einem Gerät mit autorisiertem USB-Debugging eventuell per `adb shell run-as de.schellboy.calsyncfamily id` lesend untersucht werden. Für eine technische Sicherung müsste die Debug-App angehalten sein. Sichere dann die zusammengehörigen Datenbankdateien einschließlich eines vorhandenen WAL und die Einstellungen verschlüsselt, prüfe die Kopie offline und teste die Wiederherstellung separat. Das ist eine mögliche Notfallsicherung. Eine regulär signierte Release-App bietet damit noch keinen Importweg.
- Der Alt-Migrationspfad in `lib/main.dart` kann beim Start bei passenden alten Einstellungen zunächst gespeicherte Zieltermine löschen. Deshalb keine alten SharedPreferences oder Datenbankdateien blind in eine Release-App übernehmen.

### Empfohlener Ablauf

1. Erhalte die Debug-Installation und die passende Debug-APK. Für eine spätere Sicherung unterbreche die automatische Synchronisierung in beiden Profilen und stoppe die App in den Android-App-Einstellungen. Bewahre Kalendername, Konto und Profiloptionen als Referenz auf. Wechsle keine Zielkalender in den Profilen und lösche keine Profile.
2. Vor dem Wechsel braucht die App einen getrennt geprüften Export/Import. Ein Export aus einem mit demselben bisherigen Debug-Zertifikat signierten Update kann die vorhandenen App-Daten lesen. Falls dieses Zertifikat fehlt, prüfe zuerst die lesende Debug-Sicherung auf dem Xiaomi. Ohne verifizierten Export oder wiederherstellbare Sicherung bleibt die Debug-Installation bestehen.
3. Erprobe den Wechsel auf einem separaten Android-Testgerät oder Emulator mit synthetischen Kalendern. Der Import soll Profil-IDs, Zuordnungen und die Liste erstellter Termine zusammen übernehmen. Er muss fehlende oder geänderte Kalender- und Termin-IDs sowie Serienvorkommen erkennen und automatische Jobs bis zur Freigabe unterbinden. Der Import selbst darf keine Kalendertermine schreiben. Kalender- und Ereignis-IDs hängen vom Provider und Gerät ab.
4. Prüfe auf dem Testgerät beide Profile in einer reinen Vorschau. Vorhandene Zieltermine müssen erkannt werden. Unerwartete Neuanlagen, Änderungen oder Löschungen sind ein Stoppkriterium. Erst wenn Sicherung, Wiederherstellung und Vorschau nachgewiesen sind, ist ein Wechsel auf dem Xiaomi vertretbar. Erstelle auf dem Xiaomi dann eine letzte verifizierte Sicherung. Erst nach der Freigabe des Migrationsplans folgt der einmalige Austausch der App wegen der neuen Signatur. Importiere beide Profile und die Zuordnungen, während Schreibzugriffe und automatische Jobs gesperrt sind. Prüfe anschließend beide Profile erneut in der Vorschau. Produktive Synchronisierung erfordert danach eine gesonderte Freigabe.

Dieser PR bereitet die Signierung vor. Der Export/Import, die Migrationsprobe und die Freigabe der produktiven Synchronisierung stehen noch aus.

## Eigenen Keystore unter Windows 11 erzeugen

Installiere ein JDK 21 und prüfe in PowerShell mit `Get-Command keytool.exe`, dass `keytool` verfügbar ist. Wähle einen lokalen Ordner außerhalb des Git-Checkouts und außerhalb unverschlüsselter Cloud-Synchronisation. Die folgenden Befehle sind für deine spätere Ausführung gedacht.

```powershell
$keystore = Join-Path $env:LOCALAPPDATA 'CalSyncSigning\calsync-family-release.jks'
New-Item -ItemType Directory -Force (Split-Path $keystore) | Out-Null
if (Test-Path $keystore) { throw 'Der Keystore existiert bereits. Verwende den vorhandenen Schlüssel.' }

keytool -genkeypair -storetype JKS -keystore "$keystore" -alias calsync-family-release -keyalg RSA -keysize 3072 -validity 10000
keytool -list -v -storetype JKS -keystore "$keystore" -alias calsync-family-release
```

- Gib lange, eigene Passwörter nur an den Eingabeaufforderungen ein. Für Passwortschutz und Wiederherstellung verwahre Keystore-Passwort und Schlüsselpasswort im Passwortmanager. Bei `keytool -list` prüfe, dass der Eintrag ein `PrivateKeyEntry` ist, und notiere den öffentlichen SHA-256-Zertifikatfingerabdruck. Zertifikatsangaben sind öffentlich sichtbar. Verwende dort keine personenbezogenen Angaben, die du nicht weitergeben möchtest.
- Bewahre mindestens zwei verschlüsselte Sicherungskopien des Keystores an getrennten Orten auf. Prüfe eine Kopie mit `keytool -list -v` und vergleiche ihren Fingerabdruck. Verliere weder Datei noch Passwörter. Ein neu erzeugter Schlüssel ist kein Ersatz für den ursprünglichen Update-Schlüssel.
- Verwende für jedes Update dieselbe Paketkennung, denselben Schlüssel und einen höheren Android-`versionCode` (Zahl nach `+` in `pubspec.yaml`). Prüfe vor der Installation den Fingerabdruck aus `apksigner verify --print-certs app-release.apk` gegen deine Aufzeichnung. Die APK enthält das öffentliche Signaturzertifikat. Der private Schlüssel und seine Passwörter bleiben außerhalb der APK.

## GitHub Actions später einrichten

Verwende für den signierten Build ein eigenständiges privates Repository mit dem geprüften Quellstand. `Schellboy/calsync-family` ist derzeit ein öffentlicher Fork, dessen Sichtbarkeit GitHub innerhalb des Fork-Netzwerks nicht unabhängig ändern lässt. Der manuelle Release-Workflow erlaubt Builds von `main` in einem privaten Repository. Lege dort unter **Settings → Environments** das Environment `android-release` an. Beschränke dessen zulässige Deployment-Branches auf `main` und aktiviere eine Freigabe, falls dein GitHub-Tarif sie unterstützt. Hinterlege diese vier **Environment secrets**:

| Secret | Wert |
| --- | --- |
| `CALSYNCFAMILY_KEYSTORE_BASE64` | Base64 der vollständigen JKS-Datei |
| `CALSYNCFAMILY_STORE_PASSWORD` | Passwort des Keystores |
| `CALSYNCFAMILY_KEY_ALIAS` | Alias aus `keytool`, im Beispiel `calsync-family-release` |
| `CALSYNCFAMILY_KEY_PASSWORD` | Passwort des Schlüsseleintrags |

Wenn die GitHub CLI installiert und angemeldet ist, übergib den Base64-Wert direkt aus PowerShell per Pipeline. Ersetze `OWNER/PRIVATE-REPOSITORY` durch das private Ziel-Repository. Base64 ist keine Verschlüsselung.

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes($keystore)) |
  gh secret set CALSYNCFAMILY_KEYSTORE_BASE64 --env android-release --repo 'OWNER/PRIVATE-REPOSITORY'
```

Gib die Passwörter direkt in den GitHub-Einstellungen ein. Speichere weder Secret-Werte noch den Base64-Text im Checkout, in Chatnachrichten oder in Diagnoseausgaben. Der Runner legt den Keystore temporär außerhalb des Checkouts an und entfernt ihn nach dem Signierschritt. Starte nach der Übernahme des geprüften Workflows im privaten Repository unter **Actions → Build signed Android release APK → Run workflow** einen Lauf auf `main`. Lade nach Erfolg das Artefakt `CalSync-Family-Release-APK` herunter und vergleiche seinen Zertifikatfingerabdruck. Der Workflow veröffentlicht nur die verifizierte APK als Actions-Artefakt. Er erstellt keine GitHub Releases und lädt nichts in den Play Store hoch.

Für einen lokalen Release-Build kann die ignorierte Datei `android/key.properties` verwendet werden. Sie erwartet `storeFile`, `storePassword`, `keyAlias` und `keyPassword`. Verwende unter Windows einen absoluten Keystore-Pfad mit Schrägstrichen. Die Datei enthält Klartext und gehört nur auf einen vertrauenswürdigen Rechner. Der Debug-Build verwendet weiter seine bisherige Debug-Signierung.
