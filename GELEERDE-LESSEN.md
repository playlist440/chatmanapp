# Geleerde lessen uit bestaande Matrix-clients

Onderzoek naar de issue-lijsten van vergelijkbare clients, om hun fouten niet te herhalen.
Uitgevoerd op 5 september 2026.

## De onderzochte clients

| Client | Licentie | Sterren | Open issues | Laatste commit |
|---|---|---|---|---|
| [FluffyChat](https://github.com/krille-chan/fluffychat) | AGPL-3.0 | 3105 | 563 | actief |
| [Syphon](https://github.com/syphon-org/syphon) | AGPL-3.0 | 1058 | 153 | aug 2024 |
| [Quadrix](https://github.com/alariej/quadrix) | geen | 104 | 19 | nov 2023 |
| [Element X iOS](https://github.com/element-hq/element-x-ios) | AGPL-3.0 | 936 | 404 | actief |

Tammy kon ik niet vinden als publieke repository.

**Eerste les zit al in die tabel.** Syphon en Quadrix zijn dood, allebei eenpersoons-projecten
die een volwaardige Matrix-client wilden zijn. Quadrix heeft niet eens een licentie, wat
hergebruik juridisch onmogelijk maakt. Onze smalle scope — alleen wat de bridges kunnen — is
niet alleen een productkeuze maar ook wat dit project overleefbaar houdt.

---

## Les 1 — De eerste sync is waar iedereen breekt

Het meest consistente patroon in alle issue-lijsten.

- FluffyChat: *"(Initial) sync never completes, stuck in sync → loading loop"* — nog steeds open
- FluffyChat: *"OOM on initial sync"* — de app liep uit zijn geheugen
- Syphon: *"App lags on initial sync"*
- Syphon: **"Initial sync caused synapse crash"** — de client trok zijn eigen server omver

Die laatste is de scherpste waarschuwing: een client die zoveel tegelijk vraagt dat de
homeserver eronder bezwijkt. Bij een gebridgede account met tientallen gesprekken is dat geen
theoretisch risico.

**Wat we hebben gedaan**

`SyncFilter.initial` vraagt bij de eerste sync één bericht per gesprek, geen volledige
geschiedenis. Genoeg voor de gesprekkenlijst, en de rest komt pas als je een gesprek opent.

**Wat nog moet**

Geen enkele losse aanvraag per kamer bij de eerste sync. Watch The Matrix doet dit wél — daar
worden per nieuwe kamer drie aparte verzoeken gedaan, wat bij vijftig gesprekken ruim honderd
gelijktijdige verzoeken oplevert. Precies het gedrag dat Syphon's server omvertrok.

## Les 2 — De oneindige laadspinner

FluffyChat's *"stuck in sync → loading loop"* verdient een eigen les, want **die bug zat ook in
onze code**.

Mislukte de eerste sync, dan bleef `RootView` een spinner tonen terwijl de lus in stilte bleef
proberen. Geen foutmelding, geen knop, geen uitweg — precies waar FluffyChat-gebruikers al
jaren op vastlopen.

**Opgelost.** Er is nu een aparte toestand `firstSyncFailed` met een reden en twee knoppen:
opnieuw proberen, of uitloggen. Het onderscheid met `offline` is bewust: mét gecachte
gesprekken is een storing een balkje en blijft de app bruikbaar, zónder cache moet de app
gewoon zeggen wat er mis is.

## Les 3 — Meldingen zijn de grootste bron van klachten

Vier van FluffyChat's zestien meest besproken open issues:

- *"FluffyChat doesn't register notification targets if any FluffyChat is registered"* — 28 reacties
- *"notifications not working"* — 16 reacties
- *"unifiedpush doesn't work"* — 12 reacties
- *"Show message content in iOS push notification"* — 18 reacties

Het patroon is niet dat push moeilijk is, maar dat het **onzichtbaar faalt**. Iemand krijgt
niets en kan nergens zien waarom.

**Wat dat voor Chatman betekent**

De instellingen moeten tonen of push daadwerkelijk geregistreerd is: staat er een pusher op de
server, welk apparaat-token, wanneer voor het laatst iets ontvangen. Plus een testknop. Dat is
het verschil tussen een bugrapport en zelf zien wat er mis is.

Die eerste issue is trouwens ook een concrete valkuil: registreert een tweede apparaat zich met
dezelfde sleutel, dan verdringt het de eerste. Wij zetten `append: false` en gebruiken aparte
app-ID's voor telefoon en horloge, precies om dat te voorkomen.

## Les 4 — Versleuteling veroorzaakt de ergste bug die er is

- Syphon: *"Messages not readable after app restart"* — sleutels kwijt, berichten voorgoed onleesbaar
- Syphon: *"Give user the possibility to opt-out of E2EE"* — 13 reacties, mensen wíllen het uitzetten
- FluffyChat: *"Add room key import & export from file"* — 22 reacties

Je eigen berichten niet meer kunnen lezen is onherstelbaar en onvergeeflijk. Onze keuze om
E2EE over te slaan haalt deze hele categorie weg.

Dat is geen privacyconcessie in onze opzet: de bridge ontsleutelt Signal sowieso op je eigen
server, dus Matrix-versleuteling erbovenop beschermt tegen niemand die niet al toegang heeft.

## Les 5 — Berichten in de verkeerde volgorde

FluffyChat: *"Messages can end up shown and saved in the wrong order when sending before
synced"*.

Onze optimistische verzending geeft het lokale bericht `Date.now` mee, terwijl de server later
zijn eigen tijdstempel bepaalt. Bij een klokverschil kan een verzonden bericht dus verspringen
zodra het via sync terugkomt.

**Nog niet opgelost.** Aandachtspunt zodra we op echte hardware testen.

## Les 6 — Iedereen wil sliding sync, niemand heeft het

- FluffyChat: *"[FR] instant sync / Sliding sync"* — open
- Syphon: *"Support sync v3"* — open

Voor een account met honderden kamers is klassieke `/sync` te zwaar. Voor één gebruiker met
gebridgede gesprekken en strakke filters is het prima. Wel iets om te heroverwegen als de
eerste sync in de praktijk traag blijkt.

---

## Samengevat: wat ons beschermt

| Risico uit de praktijk | Onze verdediging |
|---|---|
| Eerste sync loopt vast of sloopt de server | Filter met één bericht per gesprek; geen aanvragen per kamer |
| Eeuwige laadspinner | Aparte `firstSyncFailed`-toestand met reden en knoppen |
| Meldingen falen onzichtbaar | Zichtbare registratiestatus in instellingen *(nog te bouwen)* |
| Berichten onleesbaar na herstart | Geen E2EE |
| Dubbele push-registratie | `append: false`, aparte app-ID per apparaat |
| Project sterft aan zijn eigen omvang | Alleen bouwen wat de bridges kunnen |
