# Eerste test op je eigen iPhone en Apple Watch

## Wat er al goed staat

- Je iPhone en je Ultra staan in ontwikkelaarsmodus
- Xcode heeft een ontwikkelteam ingesteld en tekent automatisch
- Er zijn geen functies in gebruik die een betaald Apple-account vereisen
- De horloge-app zit ingebouwd in de iPhone-app, net als bij WhatsApp of Tidal

## De stappen

**1. iPhone aansluiten met een kabel.** Draadloos werkt ook, maar de eerste
keer gaat met een kabel merkbaar soepeler.

**2. In Xcode het schema `Chatman` kiezen** en bij het doel je eigen iPhone
selecteren in plaats van een simulator. Dan op Run.

**3. Op je iPhone het profiel vertrouwen.** De eerste keer weigert iOS de app
met een melding over een niet-vertrouwde ontwikkelaar. Ga naar
Instellingen → Algemeen → VPN en apparaatbeheer, tik je eigen Apple ID aan en
kies Vertrouwen. Start de app daarna opnieuw.

**4. Het horloge komt vanzelf.** De Watch-app op je telefoon installeert
Chatman op je Ultra zodra de iPhone-app erop staat. Dat duurt een paar
minuten en gebeurt op de achtergrond. Zie je hem niet, kijk dan in de
Watch-app onder Beschikbare apps.

**5. Inloggen op je iPhone.** Vul je Matrix-ID en wachtwoord in, laat het
serverveld leeg. Na ongeveer tien seconden verschijnt dat veld vanzelf —
vul daar in:

    matrix.example.com:8443

**6. Contacten toestaan** wanneer daarom gevraagd wordt. Namen uit je
adresboek krijgen dan voorrang op de namen die Signal en WhatsApp doorgeven.

**7. Het horloge hoeft niets.** Die neemt je sessie over van de telefoon,
inclusief de namen uit je adresboek.

## Wat je kunt verwachten

**Werkt:** gesprekken lezen en sturen op beide apparaten, foto's bekijken,
reageren met emoji, nieuwe gesprekken beginnen, en het horloge zelfstandig
op 4G zonder je telefoon in de buurt.

**Werkt nog niet:** meldingen. Daarvoor is een APNs-sleutel nodig en die
vereist het betaalde ontwikkelaarsaccount. Zolang dat er niet is,
synchroniseert het horloge alleen terwijl de app open is.

## De beperking van een gratis account

Een app die met een gratis Apple ID is ondertekend, werkt **zeven dagen**.
Daarna weigert hij te starten en zet je hem opnieuw vanuit Xcode op je
toestel. Dat is de enige reden om die 99 euro te overwegen — dat, en
meldingen.
