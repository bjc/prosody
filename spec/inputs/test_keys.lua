local test_keys = {
	-- ECDSA keypair from jwt.io
	ecdsa_private_pem = [[
-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgevZzL1gdAFr88hb2
OF/2NxApJCzGCEDdfSp6VQO30hyhRANCAAQRWz+jn65BtOMvdyHKcvjBeBSDZH2r
1RTwjmYSi9R/zpBnuQ4EiMnCqfMPWiZqB4QdbAd0E7oH50VpuZ1P087G
-----END PRIVATE KEY-----
]];

	ecdsa_public_pem = [[
-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEEVs/o5+uQbTjL3chynL4wXgUg2R9
q9UU8I5mEovUf86QZ7kOBIjJwqnzD1omageEHWwHdBO6B+dFabmdT9POxg==
-----END PUBLIC KEY-----
]];

	-- Self-generated ECDSA keypair
	alt_ecdsa_private_pem = [[
-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgQnn4AHz2Zy+JMAgp
AZfKAm9F3s6791PstPf5XjHtETKhRANCAAScv9jI3+BOXXlCOXwmQYosIbl9mf4V
uOwfIoCYSLylAghyxO0n2of8Kji+D+4C1zxNKmZIQa4s8neaIIzXnMY1
-----END PRIVATE KEY-----
]];

	alt_ecdsa_public_pem = [[
-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEnL/YyN/gTl15Qjl8JkGKLCG5fZn+
FbjsHyKAmEi8pQIIcsTtJ9qH/Co4vg/uAtc8TSpmSEGuLPJ3miCM15zGNQ==
-----END PUBLIC KEY-----
]];

	-- JWT reference keys for ES512

	ecdsa_521_public_pem = [[
-----BEGIN PUBLIC KEY-----
MIGbMBAGByqGSM49AgEGBSuBBAAjA4GGAAQBgc4HZz+/fBbC7lmEww0AO3NK9wVZ
PDZ0VEnsaUFLEYpTzb90nITtJUcPUbvOsdZIZ1Q8fnbquAYgxXL5UgHMoywAib47
6MkyyYgPk0BXZq3mq4zImTRNuaU9slj9TVJ3ScT3L1bXwVuPJDzpr5GOFpaj+WwM
Al8G7CqwoJOsW7Kddns=
-----END PUBLIC KEY-----
]];

	ecdsa_521_private_pem = [[
-----BEGIN PRIVATE KEY-----
MIHuAgEAMBAGByqGSM49AgEGBSuBBAAjBIHWMIHTAgEBBEIBiyAa7aRHFDCh2qga
9sTUGINE5jHAFnmM8xWeT/uni5I4tNqhV5Xx0pDrmCV9mbroFtfEa0XVfKuMAxxf
Z6LM/yKhgYkDgYYABAGBzgdnP798FsLuWYTDDQA7c0r3BVk8NnRUSexpQUsRilPN
v3SchO0lRw9Ru86x1khnVDx+duq4BiDFcvlSAcyjLACJvjvoyTLJiA+TQFdmrear
jMiZNE25pT2yWP1NUndJxPcvVtfBW48kPOmvkY4WlqP5bAwCXwbsKrCgk6xbsp12
ew==
-----END PRIVATE KEY-----
]];

	-- Self-generated keys for ES512

	alt_ecdsa_521_public_pem = [[
-----BEGIN PUBLIC KEY-----
MIGbMBAGByqGSM49AgEGBSuBBAAjA4GGAAQBIxV0ecG/+qFc/kVPKs8Z6tjJEuRe
dzrEaqABY6THu7BhCjEoxPr6iRYdiFPzNruFORsCAKf/NFLSoCqyrw9S0YMA1xc+
uW01145oxT7Sp8BOH1MyOh7xNh+LFLi6X4lV6j5GQrM1sKSa3O5m0+VJmLy5b7cy
oxNCzXrnEByz+EO2nYI=
-----END PUBLIC KEY-----
]];

	alt_ecdsa_521_private_pem = [[
-----BEGIN EC PRIVATE KEY-----
MIHcAgEBBEIAV2XJQ4/5Pa5m43/AJdL4XzrRV/l7eQ1JObqmI95YDs3zxM5Mfygz
DivhvuPdZCZUR+TdZQEdYN4LpllCzrDwmTCgBwYFK4EEACOhgYkDgYYABAEjFXR5
wb/6oVz+RU8qzxnq2MkS5F53OsRqoAFjpMe7sGEKMSjE+vqJFh2IU/M2u4U5GwIA
p/80UtKgKrKvD1LRgwDXFz65bTXXjmjFPtKnwE4fUzI6HvE2H4sUuLpfiVXqPkZC
szWwpJrc7mbT5UmYvLlvtzKjE0LNeucQHLP4Q7adgg==
-----END EC PRIVATE KEY-----
]];

	-- Self-generated EdDSA (Ed25519) keypair
	eddsa_private_pem = [[
-----BEGIN PRIVATE KEY-----
MC4CAQAwBQYDK2VwBCIEIOmrajEfnqdzdJzkJ4irQMCGbYRqrl0RlwPHIw+a5b7M
-----END PRIVATE KEY-----
]];

	eddsa_public_pem = [[
-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEAFipbSXeGvPVK7eA4+hIOdutZTUUyXswVSbMGi0j1QKE=
-----END PUBLIC KEY-----
]];

	-- RSA keypair from jwt.io
	rsa_private_pem = [[
-----BEGIN PRIVATE KEY-----
MIIEvwIBADANBgkqhkiG9w0BAQEFAASCBKkwggSlAgEAAoIBAQC7VJTUt9Us8cKj
MzEfYyjiWA4R4/M2bS1GB4t7NXp98C3SC6dVMvDuictGeurT8jNbvJZHtCSuYEvu
NMoSfm76oqFvAp8Gy0iz5sxjZmSnXyCdPEovGhLa0VzMaQ8s+CLOyS56YyCFGeJZ
qgtzJ6GR3eqoYSW9b9UMvkBpZODSctWSNGj3P7jRFDO5VoTwCQAWbFnOjDfH5Ulg
p2PKSQnSJP3AJLQNFNe7br1XbrhV//eO+t51mIpGSDCUv3E0DDFcWDTH9cXDTTlR
ZVEiR2BwpZOOkE/Z0/BVnhZYL71oZV34bKfWjQIt6V/isSMahdsAASACp4ZTGtwi
VuNd9tybAgMBAAECggEBAKTmjaS6tkK8BlPXClTQ2vpz/N6uxDeS35mXpqasqskV
laAidgg/sWqpjXDbXr93otIMLlWsM+X0CqMDgSXKejLS2jx4GDjI1ZTXg++0AMJ8
sJ74pWzVDOfmCEQ/7wXs3+cbnXhKriO8Z036q92Qc1+N87SI38nkGa0ABH9CN83H
mQqt4fB7UdHzuIRe/me2PGhIq5ZBzj6h3BpoPGzEP+x3l9YmK8t/1cN0pqI+dQwY
dgfGjackLu/2qH80MCF7IyQaseZUOJyKrCLtSD/Iixv/hzDEUPfOCjFDgTpzf3cw
ta8+oE4wHCo1iI1/4TlPkwmXx4qSXtmw4aQPz7IDQvECgYEA8KNThCO2gsC2I9PQ
DM/8Cw0O983WCDY+oi+7JPiNAJwv5DYBqEZB1QYdj06YD16XlC/HAZMsMku1na2T
N0driwenQQWzoev3g2S7gRDoS/FCJSI3jJ+kjgtaA7Qmzlgk1TxODN+G1H91HW7t
0l7VnL27IWyYo2qRRK3jzxqUiPUCgYEAx0oQs2reBQGMVZnApD1jeq7n4MvNLcPv
t8b/eU9iUv6Y4Mj0Suo/AU8lYZXm8ubbqAlwz2VSVunD2tOplHyMUrtCtObAfVDU
AhCndKaA9gApgfb3xw1IKbuQ1u4IF1FJl3VtumfQn//LiH1B3rXhcdyo3/vIttEk
48RakUKClU8CgYEAzV7W3COOlDDcQd935DdtKBFRAPRPAlspQUnzMi5eSHMD/ISL
DY5IiQHbIH83D4bvXq0X7qQoSBSNP7Dvv3HYuqMhf0DaegrlBuJllFVVq9qPVRnK
xt1Il2HgxOBvbhOT+9in1BzA+YJ99UzC85O0Qz06A+CmtHEy4aZ2kj5hHjECgYEA
mNS4+A8Fkss8Js1RieK2LniBxMgmYml3pfVLKGnzmng7H2+cwPLhPIzIuwytXywh
2bzbsYEfYx3EoEVgMEpPhoarQnYPukrJO4gwE2o5Te6T5mJSZGlQJQj9q4ZB2Dfz
et6INsK0oG8XVGXSpQvQh3RUYekCZQkBBFcpqWpbIEsCgYAnM3DQf3FJoSnXaMhr
VBIovic5l0xFkEHskAjFTevO86Fsz1C2aSeRKSqGFoOQ0tmJzBEs1R6KqnHInicD
TQrKhArgLXX4v3CddjfTRJkFWDbE/CkvKZNOrcf1nhaGCPspRJj2KUkj1Fhl9Cnc
dn/RsYEONbwQSjIfMPkvxF+8HQ==
-----END PRIVATE KEY-----
]];

	rsa_public_pem = [[
-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAu1SU1LfVLPHCozMxH2Mo
4lgOEePzNm0tRgeLezV6ffAt0gunVTLw7onLRnrq0/IzW7yWR7QkrmBL7jTKEn5u
+qKhbwKfBstIs+bMY2Zkp18gnTxKLxoS2tFczGkPLPgizskuemMghRniWaoLcyeh
kd3qqGElvW/VDL5AaWTg0nLVkjRo9z+40RQzuVaE8AkAFmxZzow3x+VJYKdjykkJ
0iT9wCS0DRTXu269V264Vf/3jvredZiKRkgwlL9xNAwxXFg0x/XFw005UWVRIkdg
cKWTjpBP2dPwVZ4WWC+9aGVd+Gyn1o0CLelf4rEjGoXbAAEgAqeGUxrcIlbjXfbc
mwIDAQAB
-----END PUBLIC KEY-----
]];


	-- Self-generated RSA keypair
	alt_rsa_private_pem = [[
-----BEGIN RSA PRIVATE KEY-----
MIIEowIBAAKCAQEA4bt6kor2TomqRXfjCFe6T42ibatloyHntZCUdlDDAkUh4oJ/
4jDCXAUMYqmEsZKCPXxUGQgrmSmNnJPEDMTq3XLDsjhyN4stxEi0UVAiqqBkcEnk
qbQIJSc9v5gpQF8IuJFWRvSNic0uClFL5W9R2s5AHcOhdFYKeDuitqHT5r+dC7cy
WZs5YleKaESxmK6i6wMVhL9adAilTuETyMH0yLSh+aXsPYhjns4AbjGmiKOjqd5w
sPwllEg6rGcIUi/o79z9HN8yLMXq3XNFCCA8RI4Zh3cADI1I5fe6wk1ETN+30cDw
dGQ+uQbaQrzqmKVRNjZcorMwBjsOX5AMQBFx7wIDAQABAoIBAGxj5pZpTZ4msnEL
ASQnY9oBS4ZXr8UmaamgU/mADDOR2JR4T0ngWeNvtSPG/GV70TgO9B7U8oJoFoyh
05jCEXjmO5vfSNDs7rv6oUMONKczvybABKGMRgD5F8hhGyXCvGBLwV7u3OvXbw0b
PlNcIbTsJpNkNam0CvDyyc3iZOq+HjIqituREV7lDw0rFeAR2YfEWn4VjZsQRZUZ
XkpQJ5silrXgGemIEGqVA4YyM7i2HmTiLozfVYaVckMc02VFgOaoK9Z/wGlBxtS5
evc/IGErSA4dc7uXBEeVjhtZoBkof2JV9BNt4hl4KN9wX3tkEX5Aq1K2lirSmg2r
k+UEtwkCgYEA/5uYg25OR+jCFY/7uNS8e32Re1lgDeO+TeT1m+hcF1gCb2GBLifL
yprnuytaz1/mPqawfwbilaxntLBoa5cmNKB3zDsgv4sM451yGZ0oxU0dXpDVHblu
3nhxcaOXtb8jiSsr2MqgMbFlu7m8OupIliS+s8Pq72s6HUQQRKbJ+9MCgYEA4hQl
1W/7nDI2SR4Q3UapQnaUjmDVxX5OD+E4RpKuRF6xF7Ao2CLZusMVo8WN8YiSQP2c
RnzQNKgAVy/1zlhaaQDTs2TmSy9iStbuNZ8P+Gh6kmQXuHxwPyURSmwdpgZdL3+D
8tt6pQNQ0vsLjA9VwHmzIT+rsxPmTxKNvBdNK/UCgYByP6zqyioJMDtYAfRkiAn7
NIQLW0Z4ztvn2zgAyNoowPjNqgpgg/8t/xEm8tjzKg0y4bSwAnbSqa3s8JCrznKQ
QU1qpt8bXl6TenNeiYWIstA2zYvEbnbkz3b9cT7FSLrse7RsgR0bOQyc3QcKWl+5
ZJEsrpxbCVV/cUXIObi8awKBgQDOI8rfk+0bXhlrkBOWf/CjnpYUQK2LF4C8MALt
Lp/hzWmyjLihYx2eknUv0Fl966ZXxidxiisaaDlvRlbeIGfHqK5fu9fUpE7+qH2p
vPCF81YYF1YdrLF4kiby8iQSl2juf1nj3kY1IhHXXnsH6Y+qIg24emLntXRhkyxT
XffK5QKBgGbzEvVgDkerw1SiefAaZnLumJJXBlKjJ00Sq8YLeViyFC/sr4EfG/cV
7VYRhBw3e7RcYSBAA7uv8i3iIeCFjFooIZUARqXk4+yW753tY5nSJTWfkR7Bp5Pa
9jKloxckbZKMjH23a+ABOxomY3l93KOBvjLvMYqccuREOwaT12cn
-----END RSA PRIVATE KEY-----
]];

	alt_rsa_public_pem = [[
-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA4bt6kor2TomqRXfjCFe6
T42ibatloyHntZCUdlDDAkUh4oJ/4jDCXAUMYqmEsZKCPXxUGQgrmSmNnJPEDMTq
3XLDsjhyN4stxEi0UVAiqqBkcEnkqbQIJSc9v5gpQF8IuJFWRvSNic0uClFL5W9R
2s5AHcOhdFYKeDuitqHT5r+dC7cyWZs5YleKaESxmK6i6wMVhL9adAilTuETyMH0
yLSh+aXsPYhjns4AbjGmiKOjqd5wsPwllEg6rGcIUi/o79z9HN8yLMXq3XNFCCA8
RI4Zh3cADI1I5fe6wk1ETN+30cDwdGQ+uQbaQrzqmKVRNjZcorMwBjsOX5AMQBFx
7wIDAQAB
-----END PUBLIC KEY-----
]];
};

return test_keys;
