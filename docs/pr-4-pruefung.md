# Prüfung von PR #4 und Android-Testablauf

## Vergleich mit main

`main` (Commit `76efad4`) lief in einer separaten temporären Kopie mit **112 Tests**. Die erste Fassung von PR #4 (`bcc203d`) hatte **100 Tests**. Die 49 Fälle außerhalb der Sync-Suite blieben unverändert. Die Sync-Suite ging von 63 auf 50 Fälle zurück, während ein Dialogtest hinzukam. Die Zeit-, Serien-, Kopier- und Fehlerfälle wurden teilweise zusammengefasst. Einige alte Erwartungen wurden bewusst durch strengere Sicherheitsregeln ersetzt.

| Fälle in `main:test/sync_engine_test.dart` in ihrer Reihenfolge | Vergleich und wiederhergestellte Abdeckung |
| --- | --- |
| 1–6: 7-Tage-Grenze, Nachschlagen per ID, fehlendes Ziel | Alte Zieltermine bleiben erhalten. Ein laufender oder kürzlich vergangener Quelltermin kann per ID gefunden und erneut klassifiziert werden. Fehlendes Ziel lässt die Zuordnung zur Prüfung stehen. Fehlende Quelle allein führt zu keiner Löschung. |
| 7–12: ein- und mehrtägige Ganztagstermine, unveränderte und verschobene Kalendertage, Uhrzeit und Argumente bei Neuanlage | Ein- und mehrtägige Grenzen, unveränderter Folgelauf, Ganztagsverschiebung mit derselben Ziel-ID sowie exakte Uhrzeit und Kopieroptionen sind mit Testterminen geprüft. |
| 13–17: Ersatz, Fehlerabbruch und verwaiste Mappings | Altes Anlegen-und-Löschen durch In-place-Update ersetzt. Bestätigte Löschung räumt Zuordnung und Erstellungsnachweis auf. Lesefehler, fehlende Zielobjekte und nur aufgrund des Zeitfensters fehlende Quellen entfernen keine Zuordnungen. |
| 18–28: Schleifen, Marker, Beschreibungen und Register | Registrierung und Gegenprofil-Schleife sind geprüft. Der einfache HTML-Rahmen um eine unveränderte Beschreibung wird erkannt. Fehlender Marker trotz Register schützt den Zieltermin. Ein Update lässt Ziel-ID und Erstellungsnachweis bestehen. Nach bestätigter Löschung wird nur der eigene Registereintrag entfernt. |
| 29–31: Profilgrenzen | Statt isolierter Mock-Aufrufzählungen überprüfen SQLite-Tests getrennte Mappings für dieselbe Quell-ID und zwei Profile im gemeinsamen Ziel sowie die Sperre bei geteilter Ziel-ID. |
| 32–42: Serien, einzelne Ausnahmen, vergangene Vorkommen und Altserien | Ein und fünf Vorkommen werden einzeln registriert. Verschobene Ausnahmen behalten die ursprüngliche Zuordnung. Eine einzelne Absage bleibt vom Rest der Serie getrennt. Bei bestätigter Serienlöschung werden nur zukünftige Vorkommen vorgeschlagen. Frühere Vorkommen und uneindeutige Altserien bleiben erhalten. |
| 43–52: benutzerdefinierter Titel, Ort, Beschreibung, Titelschutz | Original- und Ersatzname, kopierte und ausgelassene Felder, Quelltiteländerungen bei festem Zielnamen und beide Übergänge des Titelschutzes werden anhand des tatsächlich geschriebenen Zieltermins geprüft. |
| 53–63: Beschreibung und Fingerabdruck | Alle elf Tests von `buildDescription` bleiben vorhanden. |

## SQLite und Android

Ein SQLite-Commit kann eine bereits ausgeführte Android-Provider-Operation nicht zurückrollen. CalSync schreibt daher vor jeder Änderung oder Löschung eine dauerhafte Absicht in SQLite, führt den Provider-Aufruf außerhalb der Datenbanktransaktion aus und bestätigt das Ergebnis in einer separaten Transaktion. Die Buchführung nutzt getrennte, kurzlebige SQLite-Verbindungen. Scheitert ein Commit, wird die Verbindung geschlossen, damit keine offene Transaktion den übrigen Datenbankzugriff blockiert.

Ein unbeantworteter Aufruf, Absturz oder fehlgeschlagener Abschluss lässt den Journaleintrag samt Profil, Ziel-ID und Operation bestehen. Übersicht und Vorschau zeigen unbestätigte Änderungen an. Weitere Schreibversuche und die Profilentfernung bleiben für dieses Profil gesperrt. Neuanlagen haben eine eigene dauerhafte Reservierung, die Wiederholungen nach einer möglicherweise erfolgreichen Provider-Neuanlage verhindert. Wurde ein Termin bereits im Provider gelöscht, kann SQLite ihn nicht wiederherstellen. Das Journal hält den Vorgang nachvollziehbar und verhindert einen stillen Wiederholungsversuch. Es gibt in dieser Fassung keine automatische Auflösung des Journals. Eine manuelle Wiederherstellung muss den Anbieterzustand und die vorhandenen Zuordnungen prüfen.

Ein Test erzwingt einen echten SQLite-Commitfehler mit einer verzögerten Fremdschlüsselprüfung, nachdem der simulierte Provider den Termin gelöscht hat. Er prüft, dass Journal und Zuordnung erhalten bleiben, die übrige Datenbank lesbar bleibt und der Provider kein zweites Mal aufgerufen wird.

## Was Android für TEAMPUNKT erkennen kann

- Änderungen an einem weiterhin lesbaren Ereignis mit gleicher lokaler ID können direkt verglichen werden. Für verschobene Serieninstanzen nutzt CalSync die ursprüngliche Zeit und die Original-ID oder eine eindeutig zuordenbare Original-Sync-ID im selben Kalender. Fehlende oder mehrdeutige Metadaten lösen keine Löschung aus.
- Ein sichtbares Löschkennzeichen (`DELETED`) oder eine Absage (`STATUS_CANCELED`) kann in der Vorschau als Beleg dienen. Der AOSP-Kalenderanbieter entfernt Ereignisse ohne Sync-ID beim Löschen unter Umständen sofort. Ein Sync-Adapter kann ein zuvor markiertes Ereignis später ebenfalls endgültig entfernen. Eine leere Abfrage lässt sich dann nicht zuverlässig von einem unvollständigen Providerbestand unterscheiden. Ein solcher hart gelöschter Termin bleibt im Ziel erhalten, bis sein tatsächlicher Zustand separat geklärt ist. Eine validierte Internetverbindung beweist keinen vollständigen TEAMPUNKT-Download.
- Die Implementierung wurde gegen den [AOSP CalendarProvider](https://android.googlesource.com/platform/packages/providers/CalendarProvider/+/refs/heads/main/src/com/android/providers/calendar/CalendarProvider2.java) geprüft. Die tatsächlichen TEAMPUNKT-/Google-Provider und HyperOS auf dem Xiaomi 14T sind noch auf einem isolierten Gerät zu prüfen. Die Flutter-Tests simulieren den Anbieter.

## Test-APK auf Android

Lade im GitHub-Actions-Lauf **Build isolated Family test APK** das Artefakt **CalSync-Family-Isolated-Test-APK** herunter. Lokal erzeugt `flutter build apk --debug --flavor familyTest` dieselbe Variante. GitHub-Artefakte des öffentlichen Forks enthalten ausschließlich die Test-APK.

Die Test-App heißt **CalSync Family Test** und verwendet `de.schellboy.calsyncfamily.test`. Sie hat einen separaten App-Speicher sowie deaktivierte Sicherung und Geräteübertragung. Periodische, reaktive und Boot-Synchronisierung stehen in dieser Variante dauerhaft auf manuell. Neue Profile sind zunächst deaktiviert. Die App kann nur in ihren eigenen lokalen Test-Zielkalender schreiben.

1. Öffne **Create Profile → Prepare isolated test calendars**. Dadurch werden ausschließlich **CalSync Family Test - Source A**, **Source B** und **Target** unter dem separaten lokalen Testkonto bereitgestellt. Wenn der Anbieter die Anlage verweigert, stoppe den Test.
2. Lege synthetische Termine in den beiden neuen Quellen an und konfiguriere je ein Profil mit dem neuen lokalen Testziel. Aktiviere die Profile von Hand. Verwende zuerst **Dry Run** und dann **Sync All**.
3. Ändere Titel, Zeiten, Ganztägigkeit und optionale Felder. Verschiebe eine Instanz einer Serie und sage eine andere ab. Kontrolliere Kopien und Vorschau. Prüfe zusätzlich, dass ein hart gelöschter lokaler Quelltermin allein keine Ziellöschung bewirkt und dass die Löschvorschau bei entzogenem Zugriff oder offline nichts löscht.
4. Prüfe Profilentfernung und Kalenderbereinigung ausschließlich mit dem isolierten Ziel. Diese Variante eignet sich für Provider- und Sicherheitsprüfungen mit lokalen Daten. Eine separate Integration mit TEAMPUNKT und Google würde ausschließlich eigens dafür eingerichtete Testkonten und neu angelegte Testkalender verwenden.
