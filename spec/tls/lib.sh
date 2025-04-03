#!/bin/bash

test_name="$(basename "$PWD")"
export failures=0

get_net_cert () {
	address="${1?}"
	sni="${2?}"
	proto="${3?}"
	local flags=()
	case "$proto" in
		"xmpp") flags=(-starttls xmpp -name "$sni");;
		"xmpps") flags=(-alpn xmpp-client);;
		"xmpp-server") flags=(-starttls xmpp-server -name "$sni");;
		"xmpps-server") flags=(-alpn xmpp-server);;
		"tls") ;;
		*) printf "EE: Unknown protocol: %s\n" "$proto" >&2; exit 1;;
	esac
	openssl s_client -connect "$address" -servername "$sni" "${flags[@]}" 2>/dev/null </dev/null |  sed -ne '/-BEGIN CERTIFICATE-/,/-END CERTIFICATE-/p'
}

get_file_cert () {
	fn="${1?}"
	sed -ne '/-BEGIN CERTIFICATE-/,/-END CERTIFICATE-/p' "$fn"
}

expect_cert () {
	fn="${1?}"
	address="${2?}"
	sni="${3?}"
	proto="${4?}"
	net_cert="$(get_net_cert "$address" "$sni" "$proto")"
	file_cert="$(get_file_cert "$fn")"
	if [[ "$file_cert" != "$net_cert" ]]; then
		echo "---"
		echo "NOT OK: $test_name: Expected $fn on $address (SNI $sni)"
		echo "Received:"
		openssl x509 -in <(echo "$net_cert") -text
		echo "---"
		failures=1;
		return 1;
	fi
	echo "OK: $test_name: $fn observed on $address (SNI $sni)"
	return 0;
}
