# Uitbrengen

Twee wegen, en ze sluiten elkaar niet uit: de broncode op GitHub, en de app in
de App Store. De eerste kost een middag, de tweede kost geld en geduld.

---

## Deel 1 · GitHub

### Wat er niet in mag

Eén ding is echt belangrijk: **je ingevulde stackbestand hoort er niet in.**
Daarin staan de as_tokens en hs_tokens van je bruggen, je databasewachtwoorden en
je `registration_shared_secret`. Met dat eerste kan iemand namens jouw bruggen
praten; met dat laatste kan iemand accounts op je server aanmaken.

In deze repo staat daarom `server/matrix-stack.example.yml`, met overal
`VUL-IN-…` in plaats van geheimen. Je eigen versie blijft buiten de repo, en
`.gitignore` houdt `matrix-stack.yml`, `fase1-matrix-stack.yml` en `GEHEIMEN.txt`
tegen.

Voor de zekerheid, vóór je pusht:

```bash
git grep -nE "as_token: \"[0-9a-f]{32}|PASSWORD '[^V]" || echo "schoon"
```

Zijn er ooit geheimen in een commit beland, dan is het niet genoeg om ze in een
volgende commit weg te halen — ze staan dan nog in de geschiedenis. Dan draai je
ze om: nieuwe tokens genereren, stack opnieuw uitrollen.

### Wat er wel in staat

- de app, met `ChatmanKit` als los te testen pakket
- `server/` met het voorbeeldbestand en `nieuwe-brug.sh`
- `README.md`, `PRIVACY.md`, `LICENSE` (MIT), dit bestand

### Wat een ander moet aanpassen

Iemand die dit zelf bouwt, verandert twee dingen: het team bij Signing, en de
bundle-ID's van de vier targets (`com.example.Chatman` en de drie die daaronder
hangen). De keychain-groep zoekt zichzelf sinds kort uit op basis van die
bundle-ID, dus dat hoeft niet meer met de hand.

### De repo klaarzetten

```bash
git init -b main
git add .
git commit -m "Chatman 1.0"
gh repo create chatman --public --source=. --push
```

---

## Deel 2 · App Store

### Wat het kost en waar je begint

Het [Apple Developer Program](https://developer.apple.com/programs/) kost €99 per
jaar. Als particulier wordt je eigen naam de verkoper in de winkel; wil je een
bedrijfsnaam, dan heb je een KvK-nummer en een D-U-N-S-nummer nodig, en dat duurt
weken langer. Voor dit project: particulier.

Wat je er meteen bij krijgt en nu mist: certificaten die een jaar geldig zijn in
plaats van zeven dagen, pushmeldingen, App Groups, en TestFlight.

### De volgorde

1. **Inschrijven** en wachten tot Apple je account goedkeurt (uren tot dagen).
2. **App ID's registreren** in het developerportaal voor alle vier de bundle-ID's,
   met de capabilities die je gebruikt (keychain sharing; push als je dat toevoegt).
3. **App aanmaken** in [App Store Connect](https://appstoreconnect.apple.com).
   De naam moet uniek zijn in de hele winkel — "Chatman" kan al bezet zijn, kijk
   dat eerst na.
4. **Archiveren** in Xcode: Product → Archive, dan Distribute App → App Store
   Connect. Het versienummer (`1.0`) mag blijven staan tussen uploads, het
   buildnummer moet elke keer omhoog.
5. **TestFlight** — installeer je eigen build eerst daaruit op je telefoon. Dit
   is ook de plek waar je hem aan een handvol anderen kunt geven zonder ooit door
   de winkelreview te hoeven.
6. **Ter beoordeling insturen**, en dan wachten. Meestal een dag, soms drie.

### Wat je moet aanleveren

- **Schermafbeeldingen**: 6,9-inch iPhone (1320 × 2868). En omdat er een
  watch-app in zit, ook Apple Watch-afbeeldingen — voor de Ultra 410 × 502.
- **App-icoon** 1024 × 1024, zonder alfakanaal en zonder ronde hoeken. Het icoon
  in deze repo voldoet daaraan.
- **Privacybeleid-URL**. Verplicht, geen uitzonderingen. `PRIVACY.md` op GitHub
  volstaat als je hem als pagina serveert.
- **Ondersteunings-URL**. Je GitHub-repo mag dat zijn.
- **Privacylabels**: het vragenformulier "App Privacy". Voor Chatman is het
  antwoord overal "niet verzameld" — de app stuurt niets naar mij, alleen naar de
  server van de gebruiker. Contacten, locatie, camera en foto's worden gebruikt,
  niet verzameld; dat onderscheid maakt het formulier zelf.
- **Exportverklaring**: de app gebruikt alleen standaard-TLS. Zet
  `ITSAppUsesNonExemptEncryption` op `false` in de Info.plist, dan vraagt Apple er
  niet elke upload opnieuw naar.

### De drie dingen die je afgekeurd kunnen krijgen

**1 · De reviewer kan er niet in.** Dit is verreweg het grootste risico.
Chatman werkt alleen tegen een Matrix-server met bruggen, en die heeft de
reviewer niet. Een app die bij het openen om een servernaam vraagt en verder
niets doet, wordt afgekeurd onder richtlijn 2.1 zonder dat iemand verder kijkt.

Wat je doet: maak op je eigen server een testaccount aan met twee of drie
gesprekken erin, en zet gebruikersnaam, wachtwoord, servernaam én poort in het
veld "App Review Information → Notes". Schrijf erbij wat de app is en waarom er
een eigen server bij hoort. Houd dat account daarna in leven — bij elke update
kijken ze opnieuw.

**2 · De naam en het mannetje.** Chatman is een reclamefiguur van iemand anders,
en "supersnel op MSN" is hun leus. Voor een gratis app van een particulier is de
kans op gedoe klein, maar het is niet nul: Apple vraagt soms om bewijs dat je de
rechten hebt op een herkenbaar merk of personage, en de rechthebbende kan altijd
zelf aankloppen. Drie opties, in volgorde van gemak: er niets aan doen en het
risico accepteren; alleen buiten de winkel uitbrengen (GitHub, TestFlight); of
een eigen naam en figuur maken voor de winkelversie en Chatman houden voor jezelf.

**3 · De netwerken van anderen.** WhatsApp en Signal staan onofficiële clients
in hun voorwaarden niet toe, en richtlijn 5.2.5 zegt dat een app geen dienst mag
gebruiken in strijd met diens voorwaarden. Jouw verdediging is sterk en klopt:
Chatman praat helemaal niet met WhatsApp. Het is een Matrix-client die met jouw
server praat; de brug op jouw server doet de rest. Zeg dat ook zo in de
reviewnotities, vóór iemand het hoeft te vragen.

Nog twee kleinere dingen die kunnen langskomen: een berichtenapp wordt soms
gevraagd om mensen te kunnen blokkeren of iets te melden (dat zit er nu niet in),
en de inlogpagina's van Meta en X in de app tellen als "web content" bij het
bepalen van de leeftijdsclassificatie.

### Als het je te veel wordt

Dat is een reële uitkomst, en geen verlies. **TestFlight** laat je de app een
jaar lang aan honderd mensen geven met een veel lichtere review, en interne
testers helemaal zonder. **GitHub alleen** werkt ook: wie het wil draaien, heeft
toch al een eigen server — die kan ook Xcode openen.

De App Store is de moeite waard als je wilt dat mensen hem vinden zonder van je
gehoord te hebben. Voor een app die pas werkt nadat je zelf een Matrix-server
hebt opgezet, is dat een kleinere groep dan het lijkt.
