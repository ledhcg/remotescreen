// Auto-generated file: OpenSSL (DES/AES) and hashlib (MD5) as independent reference sources. Do not edit by hand.
struct VNCVector { let password: String; let challenge: String; let response: String }
struct AESVector { let key: String; let plaintext: String; let ciphertext: String }
struct MD5Vector { let input: String; let digest: String }

let vncVectors: [VNCVector] = [
    VNCVector(password: "password", challenge: "6466bfda869c5458780a926ccdc9aa78", response: "d75c80abd8e67189ad36ac98ffe9ebac"),
    VNCVector(password: "ab", challenge: "bcdba2453c211aaa0a07f67b25775519", response: "a668dffb8fb35f21326988ef4b96eea7"),
    VNCVector(password: "verylongpassword", challenge: "e15fd882df102c8fc04c3c5afc64c82d", response: "6d353a559549e7f9980dfee583b35f2a"),
    VNCVector(password: "", challenge: "533d59a36c4749a21f101dfc492c3c17", response: "6c2d083a6d7b2803f893fdbf1449e341"),
    VNCVector(password: "Pässw", challenge: "80fcf59b588cd47699ef4c6534bce598", response: "7e1f86f8e734f6029ba54594885c667c"),
]

let aesVectors: [AESVector] = [
    AESVector(key: "000102030405060708090a0b0c0d0e0f", plaintext: "00112233445566778899aabbccddeeff", ciphertext: "69c4e0d86a7b0430d8cdb78070b4c55a"),  // FIPS-197 C.1
    AESVector(key: "793a36b87a9385fe8bc9c0422bb1538a", plaintext: "963a19efe2c280fa17f78fdb85386832", ciphertext: "8e41fde7beccab5d79351c536f8bdf76"),
    AESVector(key: "284460a938022c9f419d01bc8b72a559", plaintext: "2cf558f824b7fdf7d4fe9a42666ca06d6d957097407c75b35206b71b399fbe6a368dd69d7e6d63eec58eb474ac01d4c693af82fa3d7d3c100d3da88f3e7adfc933a0a92d8ecc31c6d513e6dab4aeab417cf689fb876b5684e015e7c2b549128601232d03581ca2feee6ba007dac20f814e38b513d24229851723f92080eff8ea", ciphertext: "6e4a9a27fd78a4350632970feaf64f0bee586bee510832280528a5f27b7f014de4ce861abebd9270a2e6d636a6bad55a0025207d04c4434c13fd6641fc966dc5f6f43dd9a90f2ca2afc3f948afb57e4295fbe360381bb0b68a6ffccb42726d02970e68f2e49ea2957da3f75e44ce3d91958b4be1341500a472e88bd76b3636a7"),
]

let md5Vectors: [MD5Vector] = [
    MD5Vector(input: "", digest: "d41d8cd98f00b204e9800998ecf8427e"),
    MD5Vector(input: "616263", digest: "900150983cd24fb0d6963f7d28e17f72"),
    MD5Vector(input: "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f606162636465666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9fa0a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbcbdbebfc0c1c2c3c4c5c6c7c8c9cacbcccdcecfd0d1d2d3d4d5d6d7d8d9dadbdcdddedfe0e1e2e3e4e5e6e7e8e9eaebecedeeeff0f1f2f3f4f5f6f7f8f9fafbfcfdfeff", digest: "e2c865db4162bed963bfaa9ef6ac18f0"),
    MD5Vector(input: "ace6a9cf4324dfe6b64232bf2ee31a1ae32cf3b40072d1d91981032c43f7faf018860d92efb54a29630cfe39d0a17939b0902bbccadd1a9b993cec5bb1908dcbd9ae0d8d432277f5b4df8d3d3dab7b2d1e29fcb83848f9ab428e5e537f3e03838e8b662f1ba631b2b60e16788d7b8abb82ac87f73c80a91f8858a9283965f75f291e6d257e09e62c82e9f78c3abcb22c5b4afbf803d979bfe828036d1036ebe2a6fad778c32112ee98b9a0f1f9104dfb1213b8b934c186dd27a734c2514f97f9febabee83bc4bf9eb4efe414e94791f4f2b43008833d2491bc3fde2dd1705945b905d597e3811cfde45c26f913d6cb773991296aa0eadcb01477bda3eda775ef90652a8b39d4b4d10d0671661c561d5374417c9246c5e045dfd80e8b88ebcf6bdf606d0b98ceafcd25313a702fd8174b8be4207fec55f57a8e256ade4c2a984a9f795e68ce1c3d4faba0b045b0d48eba2fc8461322bcefb7d302293ecea4e3d8d77905327e36be362c0b1ac35d2b720355853e6860c57003681b1263ea2d3b0d3613b25d66fa1b1fb479d5ff01135310884c2313d01793f18080d18b49130d19b8df010df4244941a9655ec7fea85b5e3725784fa4d1b4d1338836c7a946c17d0fbdee60b795c7644abf29b7f524db130d33a98b8b0c8d2e4f8f52e7b4e6d4652ea64700103366db23235e5d62517d40d543a80f93785c02aa581ed04ee4d8a6", digest: "5ff393447295541b6d3c67f8aadcf0b7"),
]
