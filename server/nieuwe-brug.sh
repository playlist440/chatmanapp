#!/bin/bash
#
# Zet een extra brug klaar voor je Matrix-stack.
#
# Je domein komt uit $CHATMAN_DOMEIN, of anders uit de regel hieronder.
#
# Signal en WhatsApp draaien al. Elke andere brug van mautrix werkt precies
# hetzelfde — zelfde image-familie, zelfde provisioning-koppeling, zelfde
# plek in Traefik — maar hij heeft wel zes losse stukjes nodig die op zes
# verschillende plaatsen in het stackbestand horen. Dit script schrijft die
# zes stukjes voor je uit, met verse geheimen.
#
# Gebruik:  ./nieuwe-brug.sh telegram
#           ./nieuwe-brug.sh              (laat zien wat er te kiezen valt)
#
# De uitvoer bevat tokens en een databasewachtwoord. Stuur hem niet door,
# plak hem alleen in je stack in Portainer.

set -u

# Vul hier je eigen domein in.
DOMEIN="${CHATMAN_DOMEIN:-matrix.example.com}"

# netwerk|image|poort|bot|ghost-voorvoegsel|extra config
BRUGGEN="
telegram|mautrix/telegram|29330|telegrambot|telegram_|
discord|mautrix/discord|29331|discordbot|discord_|
slack|mautrix/slack|29332|slackbot|slack_|
facebook|mautrix/meta|29333|facebookbot|facebook_|mode: facebook
instagram|mautrix/meta|29334|instagrambot|instagram_|mode: instagram
gmessages|mautrix/gmessages|29335|gmessagesbot|gmessages_|
gvoice|mautrix/gvoice|29336|gvoicebot|gvoice_|
twitter|mautrix/twitter|29337|twitterbot|twitter_|
linkedin|mautrix/linkedin|29338|linkedinbot|linkedin_|
bluesky|mautrix/bluesky|29339|blueskybot|bluesky_|
irc|mautrix/irc|29340|ircbot|irc_|
zulip|mautrix/zulip|29341|zulipbot|zulip_|
"

NETWERK="${1:-}"

if [ -z "$NETWERK" ]; then
    echo "Welke brug wil je erbij? Kies er één:"
    echo
    echo "$BRUGGEN" | grep . | cut -d'|' -f1 | sed 's/^/  /'
    echo
    echo "Bijvoorbeeld:  ./nieuwe-brug.sh telegram"
    exit 0
fi

REGEL=$(echo "$BRUGGEN" | grep "^$NETWERK|" || true)
if [ -z "$REGEL" ]; then
    echo "✗ '$NETWERK' ken ik niet. Draai het script zonder argument voor de lijst."
    exit 1
fi

IMAGE=$(echo "$REGEL" | cut -d'|' -f2)
POORT=$(echo "$REGEL" | cut -d'|' -f3)
BOT=$(echo "$REGEL" | cut -d'|' -f4)
GHOST=$(echo "$REGEL" | cut -d'|' -f5)
EXTRA=$(echo "$REGEL" | cut -d'|' -f6)

# Verse geheimen. openssl zit in macOS, dus er is niets te installeren.
AS_TOKEN=$(openssl rand -hex 32)
HS_TOKEN=$(openssl rand -hex 32)
SENDER=$(openssl rand -hex 6)
DBWACHTWOORD=$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)
DBGEBRUIKER="mautrix$NETWERK"

# Bash 3.2 op macOS kent ${x^} en consorten niet, dus met de hand.
NAAM=$(echo "$NETWERK" | awk '{print toupper(substr($0,1,1)) substr($0,2)}')
DOMEIN_REGEX=$(echo "$DOMEIN" | sed 's/\./\\./g')

cat <<EOF
# ─────────────────────────────────────────────────────────────────────────
# $NETWERK — plak de zes blokken hieronder in fase1-matrix-stack.yml.
# Elk blok zegt erboven waar het hoort. Daarna: stack opnieuw uitrollen.
# ─────────────────────────────────────────────────────────────────────────


# ── 1 · Bij "volumes:" onderaan het bestand ──────────────────────────────

  matrix_$NETWERK:


# ── 2 · Bij "services:", naast de andere bruggen ─────────────────────────

  ${NETWERK}db-init:
    image: postgres:16-alpine
    restart: "no"
    depends_on:
      db:
        condition: service_healthy
    command: sh /init/${NETWERK}db.sh
    configs:
      - source: ${NETWERK}db
        target: /init/${NETWERK}db.sh
    labels:
      com.centurylinklabs.watchtower.enable: "false"

  ${NETWERK}-init:
    image: alpine:3.20
    restart: "no"
    command: sh -c "mkdir -p /data; cp /seed/config.yaml /data/config.yaml; cp /seed/registration.yaml /data/registration.yaml; chown -R 1337:1337 /data; echo 'brug-config bijgewerkt'"
    volumes:
      - matrix_$NETWERK:/data
    configs:
      - source: ${NETWERK}config
        target: /seed/config.yaml
      - source: ${NETWERK}registration
        target: /seed/registration.yaml
    labels:
      com.centurylinklabs.watchtower.enable: "false"

  mautrix-$NETWERK:
    image: dock.mau.dev/$IMAGE:latest
    restart: unless-stopped
    depends_on:
      synapse:
        condition: service_started
      ${NETWERK}-init:
        condition: service_completed_successfully
      ${NETWERK}db-init:
        condition: service_completed_successfully
    volumes:
      - matrix_$NETWERK:/data
    labels:
      com.centurylinklabs.watchtower.enable: "false"
      # Verhoog dit bij elke wijziging aan ${NETWERK}config, anders blijft de
      # oude container gewoon staan.
      chatman.config-revisie: "1"


# ── 3 · In het "synapse:"-blok, onder "configs:" ─────────────────────────

      - source: ${NETWERK}registration
        target: /config/${NETWERK}-registration.yaml


# ── 4 · In "homeserver:", bij app_service_config_files ───────────────────

        - /config/${NETWERK}-registration.yaml


# ── 5 · In "traefikroute:" ───────────────────────────────────────────────

#   onder middlewares:
          strip-$NETWERK:
            stripPrefix:
              prefixes:
                - "/bridge/$NETWERK"

#   onder routers:
          bridge-$NETWERK:
            rule: "Host(\`$DOMEIN\`) && PathPrefix(\`/bridge/$NETWERK/\`)"
            priority: 100
            entryPoints:
              - websecure
            middlewares:
              - strip-$NETWERK
            service: mautrix-$NETWERK
            tls:
              certResolver: gandi

#   onder services (helemaal onderaan traefikroute):
          mautrix-$NETWERK:
            loadBalancer:
              servers:
                - url: "http://mautrix-$NETWERK:$POORT"


# ── 6 · Bij "configs:" ───────────────────────────────────────────────────

  ${NETWERK}db:
    content: |
      #!/bin/sh
      set -e
      export PGPASSWORD='WACHTWOORD-VAN-SYNAPSE-DATABASE'
      Q="psql -h db -U synapse -d postgres -tAc"
      \$\$Q "SELECT 1 FROM pg_roles WHERE rolname='$DBGEBRUIKER'" | grep -q 1 || \\
        psql -h db -U synapse -d postgres -c "CREATE USER $DBGEBRUIKER WITH PASSWORD '$DBWACHTWOORD'"
      \$\$Q "SELECT 1 FROM pg_database WHERE datname='$DBGEBRUIKER'" | grep -q 1 || \\
        psql -h db -U synapse -d postgres -c "CREATE DATABASE $DBGEBRUIKER OWNER $DBGEBRUIKER TEMPLATE template0 LC_COLLATE 'C' LC_CTYPE 'C'"
      echo '$NETWERK-database klaar'

  ${NETWERK}registration:
    content: |
      id: $NETWERK
      url: http://mautrix-$NETWERK:$POORT
      as_token: "$AS_TOKEN"
      hs_token: "$HS_TOKEN"
      sender_localpart: "_bot_$SENDER"
      rate_limited: false
      namespaces:
        users:
          - regex: '^@$GHOST.*:$DOMEIN_REGEX\$'
            exclusive: true
          - regex: '^@$BOT:$DOMEIN_REGEX\$'
            exclusive: true
          # Niet-exclusief: dit laat de brug namens jou spreken, zodat wat je
          # zelf op je telefoon stuurt niet als schaduwaccount binnenkomt.
          - regex: '^@.*:$DOMEIN_REGEX\$'
            exclusive: false
      de.sorunome.msc2409.push_ephemeral: true
      push_ephemeral: true
      receive_ephemeral: true

  ${NETWERK}config:
    content: |
      bridge:
        # De brug laat een leesbevestiging achter zodra hij een bericht heeft
        # doorgegeven. Dat is wat Chatman onder je bericht laat zien.
        delivery_receipts: true
        permissions:
          "$DOMEIN": admin

      database:
        type: postgres
        uri: postgres://$DBGEBRUIKER:$DBWACHTWOORD@db/$DBGEBRUIKER?sslmode=disable

      homeserver:
        address: http://synapse:8008
        domain: $DOMEIN
        software: standard

      appservice:
        hostname: 0.0.0.0
        port: $POORT
        id: $NETWERK
        bot:
          username: $BOT
          displayname: $NAAM
        as_token: "$AS_TOKEN"
        hs_token: "$HS_TOKEN"
        username_template: ${GHOST}{{.}}

      provisioning:
        # Hiermee mag Chatman het inloggen afhandelen via een gewone HTTP-
        # koppeling, met je eigen Matrix-token als legitimatie.
        shared_secret: generate
        allow_matrix_auth: true

      backfill:
        enabled: true
        max_initial_messages: 50
        max_catchup_messages: 500

      double_puppet:
        secrets:
          $DOMEIN: "as_token:$AS_TOKEN"

      encryption:
        # Bewust uit: Chatman leest geen versleutelde kamers.
        allow: false
        default: false
$(if [ -n "$EXTRA" ]; then printf '\n      network:\n        %s\n' "$EXTRA"; fi)
      logging:
        # Op debug schrijft de brug de inhoud van je berichten in het logboek.
        min_level: info
        writers:
          - type: stdout
            format: pretty-colored


# ─────────────────────────────────────────────────────────────────────────
# Let op bij blok 6: vul in ${NETWERK}db het wachtwoord van je synapse-
# databasegebruiker in, op de plek waar nu WACHTWOORD-VAN-SYNAPSE-DATABASE
# staat. Dat staat al in je stack bij de andere db-init-scripts.
#
# Daarna in Chatman: Instellingen → Account toevoegen → $NETWERK.
# ─────────────────────────────────────────────────────────────────────────
EOF
