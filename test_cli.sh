#!/bin/bash

echo "=== nostr_access CLI Test ==="
echo

echo "1. Basic filter generation:"
./nostr_access --bare -k 1 -l 10
echo

echo "2. Multiple authors and kinds:"
./nostr_access --bare -a pubkey1 -a pubkey2 -k 1 -k 6
echo

echo "3. With tags:"
./nostr_access --bare -k 1 -t e=event123 -t p=pubkey456
echo

echo "4. With shortcut tags:"
./nostr_access --bare -k 30000 -d mylist -e event123 -p pubkey456
echo

echo "5. Full REQ format:"
./nostr_access -k 1 -l 5
echo

echo "6. With time filters:"
./nostr_access --bare -k 1 -s 1700000000 -u 1700003600
echo

echo "7. Pagination options:"
./nostr_access --bare --paginate --paginate-global-limit 100 --paginate-interval 5s -k 1
echo

echo "=== Test completed ==="
