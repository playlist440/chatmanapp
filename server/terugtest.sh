#!/bin/bash
#
# Haalt één groep uit je server voor de terugtest van de uitbarstingsregel.
#
# Wat eruit komt: per bericht het tijdstip en een onherkenbare code voor de
# afzender. Geen tekst, geen namen, geen telefoonnummers. De code is een hash
# met een zout dat dit script verzint en daarna vergeet, dus ook iemand met
# een lijst van alle nummers in de buurt kan hem niet terugrekenen.
#
# Gebruik, op de machine waar de stack draait:
#   ./terugtest.sh <db-container> "Buurtvereniging"      (zoekt de groep op naam)
#   ./terugtest.sh <db-container> '!abcdef:jouwdomein.nl' (of direct op kamer-ID)
#
# De uitvoer gaat naar terugtest-<datum>.csv. Zet dat bestand op je Mac in
#   ~/Library/Application Support/chatman-terugtest/
# en draai de tests van ChatmanKit: de terugtest leest alles wat daar staat en
# schrijft ernaast wat hij vond. Zet het bestand niet in git.

set -eu

CONTAINER="${1:?welke container draait Postgres? (docker ps)}"
ZOEK="${2:?welke groep? een naam of een kamer-ID}"

psql() { docker exec -i "$CONTAINER" psql -U synapse -d synapse -At "$@"; }

if [[ "$ZOEK" == !* ]]; then
    KAMER="$ZOEK"
else
    # Op naam, en alleen als dat precies één groep oplevert: een verkeerde groep
    # testen geeft een geruststellend en waardeloos antwoord.
    MATCHES=$(psql -v zoek="%$ZOEK%" -c \
        "SELECT room_id || ' ' || name FROM room_stats_state WHERE name ILIKE :'zoek';")
    AANTAL=$(printf "%s" "$MATCHES" | grep -c . || true)
    if [ "$AANTAL" -ne 1 ]; then
        echo "Niet precies één groep gevonden voor \"$ZOEK\":"
        printf "%s\n" "$MATCHES"
        echo "Geef het kamer-ID van de juiste mee."
        exit 1
    fi
    KAMER="${MATCHES%% *}"
fi

ZOUT=$(openssl rand -hex 16)
UIT="terugtest-$(date +%Y%m%d).csv"

psql -v kamer="$KAMER" -v zout="$ZOUT" -c "
  COPY (
    SELECT origin_server_ts, md5(sender || :'zout')
    FROM events
    WHERE room_id = :'kamer'
      AND type IN ('m.room.message', 'm.sticker', 'org.matrix.msc3381.poll.start')
      AND origin_server_ts > (extract(epoch FROM now() - interval '1 year') * 1000)::bigint
    ORDER BY origin_server_ts
  ) TO STDOUT WITH CSV;" > "$UIT"

echo "$(wc -l < "$UIT" | tr -d ' ') berichten naar $UIT"
