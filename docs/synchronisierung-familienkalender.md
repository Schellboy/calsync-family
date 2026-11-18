# Einseitige Synchronisierung in den Familienkalender

Lege für jeden lokalen TEAMPUNKT-Kalender ein eigenes Profil an. Wähle je Profil den TEAMPUNKT-Kalender als Quelle und denselben Google-Familienkalender als Ziel. Mit leerem benutzerdefiniertem Namen übernimmt die App den Originaltitel. Ort und Beschreibung folgen den bestehenden Kopieroptionen. Auch beim benutzerdefinierten Titel bleibt die bestehende Option zum Ausblenden des Originaltitels erhalten.

## Änderungen und Serien

Die Vorschau vergleicht den vollständigen Zielzustand. Aktualisierungen schreiben in den bestehenden Zieltermin und behalten seine Android-ID. Der Schreibzugriff setzt die eindeutige lokale Zuordnung, den Erstellungsnachweis und den zuletzt gelesenen Zustand des Zieltermins voraus. Wenn der Anbieter das Update ablehnt, bleiben der bisherige Termin und seine Zuordnung erhalten. Die App erstellt keinen Ersatztermin.

Serien werden weiterhin als einzelne Zieltermine abgebildet. Wenn der Android-Kalenderanbieter eine Ausnahme mit ursprünglicher Serien-ID und ursprünglichem Startzeitpunkt liefert, verwendet CalSync diese Referenz selbst nach einer Verschiebung. Wenn der Anbieter eine ursprüngliche Instanz nicht mehr liefert und die Ausnahme nicht zugeordnet werden kann, wartet CalSync auf eindeutige Daten. Ein fehlender Termin in einem Zeitfenster belegt keine Löschung. Altzuordnungen für komplette Serien bleiben zur manuellen Prüfung erhalten.

## Löschungen

Öffne **Dry Run**, um bestätigte Löschungen oder Absagen an der Quelle vorzuschauen. Die Vorschau liest Kalender und Zuordnungen. Sie schreibt weder Kalendertermine noch Zuordnungen. Erst **Review calendar deletions** und die ausdrückliche Bestätigung können die aufgeführten Zieltermine entfernen. Vor dem Schreiben prüft die App die Auswahl erneut. Ohne bestätigte Internetverbindung, Berechtigungen oder ausreichende Kalenderdaten gibt es keine Löschung. Android stellt keinen Nachweis bereit, dass TEAMPUNKT seine Serverdaten vollständig geladen hat. Fehlt ein Termin ohne Lösch- oder Absagekennzeichen im lokalen Anbieter, bleibt die Zielkopie erhalten.

Beim Entfernen eines Profils kannst du die Google-Termine behalten oder eindeutig zugeordnete Zieltermine anzeigen und ihre Löschung bestätigen. Scheitert dabei ein Kalender- oder Datenbankzugriff, stoppt die Bereinigung. Nach einem Teilerfolg bleiben das Profil pausiert und die verbliebenen oder nicht verbuchten Zuordnungen erhalten. Prüfe den Kalenderzustand, bevor du es erneut versuchst.

## Alttermine und unklare Schreibvorgänge

Nach einer Neuinstallation kann **Dry Run** markierte Zieltermine im Abgleichsfenster als mögliche Alttermine anzeigen. Der Marker verleiht CalSync keine Eigentümerschaft. Die App übernimmt und löscht diese Kandidaten nicht. Prüfe sie einzeln in Google Kalender, bevor du einen Termin dort manuell entfernst.

SQLite Version 10 ergänzt eine Reservierungstabelle und erhält Profile, Einstellungen und Zuordnungen. Ist nach einer Neuanlage unklar, ob der Anbieter geschrieben hat oder ob die Zuordnung gespeichert wurde, bleibt die Reservierung bestehen. Sie verhindert erneute Neuanlagen für diese Quellinstanz. Prüfe in diesem Fall den Zielkalender und die Zuordnungen, bevor eine Wiederherstellung vorgenommen wird. Der alte Startpfad zum Löschen von Terminen und Datenbankdateien wurde entfernt.
