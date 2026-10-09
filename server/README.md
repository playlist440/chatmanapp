# De server

Alles wat Chatman nodig heeft in één stack: Synapse, Postgres, Traefik en de
bruggen. Getest op een Debian-VM in Proxmox, uitgerold via Portainer, maar
`docker compose up -d` doet hetzelfde.

## Voordat je uitrolt

`matrix-stack.example.yml` staat vol met `VUL-IN-…`. Elk daarvan is een geheim
dat je zelf maakt:

```bash
# tokens en geheimen (één per stuk)
openssl rand -hex 32

# databasewachtwoorden
openssl rand -base64 24 | tr -d '/+=' | cut -c1-24

# de sender_localpart van een brug
echo "_bot_$(openssl rand -hex 6)"
```

Let op deze drie:

- **`as_token` en `hs_token` horen twee kanten op te kloppen.** De brug en het
  registratiebestand dat Synapse leest moeten dezelfde waarden hebben. Staat er
  bij `double_puppet.secrets` `as_token:…`, dan is dat het as_token van diezelfde
  brug — geen nieuwe.
- **De signing key maakt Synapse zelf.** Start hem één keer zonder de
  `signingkey`-config, haal het bestand uit het volume en zet het daarna vast in
  de stack. Raak je die kwijt, dan is je server een andere server.
- **Vervang `matrix.example.com` overal**, ook in de reguliere expressies bij de
  namespaces. Daar staan puntjes met een backslash ervoor.

Zet je ingevulde bestand **niet** in git. De `.gitignore` van deze repo houdt
`matrix-stack.yml` en `GEHEIMEN.txt` tegen, maar alleen als je die namen
aanhoudt.

## Poorten

De stack gaat ervan uit dat je provider poort 443 blokkeert — vandaar 8443 in
de voorbeelden en de DNS-uitdaging bij Let's Encrypt in plaats van de HTTP-
uitdaging. Werkt 443 bij jou gewoon, dan kun je dat overal terugzetten en in de
app de poort op 443 laten staan.

## Een brug erbij

```bash
CHATMAN_DOMEIN=matrix.jouwdomein.nl ./nieuwe-brug.sh telegram
```

Dat schrijft zes blokken uit — volume, containers, Synapse-registratie,
Traefik-route, database en config — met verse tokens, klaar om in je stack te
plakken. Kies uit: telegram, discord, slack, facebook, instagram, gmessages,
gvoice, twitter, linkedin, bluesky, irc, zulip.

Daarna in de app: Instellingen → Account toevoegen.

## Wat er bewust uit staat

- **Federatie.** Je server praat met niemand anders. Dat laat een hele klasse
  certificaat- en delegatieproblemen verdwijnen.
- **Registratie.** Alleen accounts die je zelf aanmaakt.
- **Encryptie in de bruggen.** Chatman leest geen versleutelde kamers, dus met
  encryptie aan zie je op je horloge alleen "Encrypted" staan. Het verkeer naar
  buiten is nog steeds TLS, en de server is van jou.
- **Debug-logging.** Op `debug` schrijven de bruggen de inhoud van je berichten
  in het logboek. Laat dat op `info`.
