# Backlog

Wat de ontwerpers vroegen voor een cijfer boven de 9,5 en wat nu nog niet gebouwd is, met de reden.

## Wacht op een betaald ontwikkelaarsaccount

- **Meldingen met antwoordknop** (iPhone en Watch): antwoorden vanuit een melding met `UNTextInputNotificationAction`, en snelle reacties. Dit vraagt pushmeldingen, en dus het push-entitlement van een betaald account plus een pushgateway op de server.
- **Eigen meldingweergave op de Watch** (`WKUserNotificationHostingController`): alleen zinvol met echte pushmeldingen.
- **Siri** ("Stuur een bericht naar Anna met Chatman" zonder het eerst in te stellen): vraagt het Siri-entitlement. De opdrachten in de app Opdrachten en Spotlight werken nu al zonder dat entitlement.
- **Communication Notifications** (een melding met de foto van de afzender): vraagt pushmeldingen en het entitlement voor Communication Notifications.

## Kan zonder betaald account, maar vraagt Xcode zelf

- **Share-extensie** (delen vanuit Foto's en Safari naar een chat): een nieuw extensie-target met een eigen App ID. Een gratis account mag maximaal 10 App IDs per 7 dagen aanmaken. Dit target maak je het veiligst in Xcode, samen.
- **App-icoon in Icon Composer** (lagen voor Default, Dark, Clear en Tinted): wordt gemaakt in de app Icon Composer, niet in code.

## Nog te testen op een echt apparaat

- VoiceOver van begin tot eind, op iPhone en Watch.
- De grootste tekstgroottes (AX5): op de iPhone worden pins en groepen dan een gewone lijst.
- De glasregelaar van iOS 27 (Helderder / Meer getint), Transparantie verminderen en Verhoog contrast, met elke achtergrond.
