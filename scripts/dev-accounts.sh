#!/usr/bin/env bash
# Creates the development accounts on both test servers. Idempotent.
set -euo pipefail

PASSWORD="${HRAFN_DEV_PASSWORD:-devpassword}"
# benvolio and mercutio belong to the XMPPIM integration suite, which runs
# alongside the chaos suite: messages to a shared account would reach both.
# tybalt and paris belong to the push suites, which need their accounts offline.
# rosaline and balthasar belong to the XMPPIM group chat suite, sampson and
# gregory to HrafnKit's: a room's traffic reaches every occupant.
# abram and peter belong to the XMPPIM media suite, friar and nurse to
# HrafnKit's: avatar notifications reach every contact.
# escalus and potpan belong to the HrafnKit reactions, replies and XEP-0490 suite.
USERS=("juliet" "romeo" "benvolio" "mercutio" "tybalt" "paris" "rosaline" "balthasar" "sampson" "gregory"
       "abram" "peter" "friar" "nurse" "escalus" "potpan" "montague" "capulet" "admin")

echo "==> prosody (alpha.test)"
for user in "${USERS[@]}"; do
  docker exec hrafn-prosody prosodyctl register "$user" alpha.test "$PASSWORD" 2>/dev/null \
    && echo "   created $user@alpha.test" \
    || echo "   $user@alpha.test already exists"
done

echo "==> ejabberd (beta.test)"
for user in "${USERS[@]}"; do
  docker exec hrafn-ejabberd bin/ejabberdctl register "$user" beta.test "$PASSWORD" >/dev/null 2>&1 \
    && echo "   created $user@beta.test" \
    || echo "   $user@beta.test already exists"
done

echo
echo "Password for all accounts: $PASSWORD"
