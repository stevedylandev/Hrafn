import Foundation

/// Certificates for `CertificateIdentityTests`: a CA and leaves for
/// host.provider.net that name example.org in different ways. Made with
/// openssl, except the IDN one (Python's `cryptography`: openssl
/// double-encodes a UTF-8 xmppAddr).
/// Valid from 2026-09-27 to 2028-12-05; the tests evaluate them at a fixed date.
enum CertificateFixtures {
    static let ca = Data(base64Encoded: """
        MIIDJzCCAg+gAwIBAgIUdTKpXLjolx457EO1z2f4O00me20wDQYJKoZIhvcNAQELBQAwGzEZMBcG
        A1UEAwwQWENoYXQgRml4dHVyZSBDQTAeFw0yNjA5MjcxMjE5NDJaFw0zNjA5MjQxMjE5NDJaMBsx
        GTAXBgNVBAMMEFhDaGF0IEZpeHR1cmUgQ0EwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIB
        AQC97IiIRAqOF4V2FGRNbqx9JqxY6+tdO9oCEGYfWNGICpPcCZbV9K+SPMrInT3rIyeEVFkW4AQk
        PyvlhpHsDKTfX3YI7uwlVs48LsowEuuBMRVlwYRPhpR4QLz5xjxC28+bE7EOjIPre8ucuZ8InGNw
        UoIPLr1IatzW0+0l+aBng8ziIKNQyQM+/YaRDiASxd6xhebu+BOiJn3wszpKSHmG+Z3jaZh2G4xA
        q+VzLWqp8im0SjL7fE5g1W14YNnpmKGOqlFLESzJB+AJ6g6THwPW+l+erTnFZSOu376ZaG9Oj3Z8
        5/AeEuDoKp3ZRERC16CA/MTYWiXRH9fuqinYaNK5AgMBAAGjYzBhMB0GA1UdDgQWBBRuAxFGRw9G
        9l3dcjpNKI1RHHH77TAfBgNVHSMEGDAWgBRuAxFGRw9G9l3dcjpNKI1RHHH77TAPBgNVHRMBAf8E
        BTADAQH/MA4GA1UdDwEB/wQEAwIBBjANBgkqhkiG9w0BAQsFAAOCAQEAqRsA5uJ/em2DGM3z9scY
        ap66yQ5rINdtArQsPkQbGme16cRxefwQkiusD3nZJ9TOunvMtu56IZjWlKbT0XZAD02OPTxWBDBk
        DZ1GUcAwjDAi/U5u1+H+LlBPvvkrOvsgnfgcHD0dnKNQf+EeI5nMuIFNBmRg/dcwrikaJlXXIDrn
        I8lpLBaBIdMwaLLBukqr+5w5nqWn6gf5sqXFvMjd+v6FS0Ex3i8/9iMK9lKjCfav9gXZYT3sdK5m
        yweTzp4GoUJ3UE1IHxMq6DoHngSOyIxOwk78T6ZdxWOhjBXuTo1MlMogHuNstKFwRoev1jdKyRhw
        vxs1DDtPrD3ROUsHgQ==
        """, options: .ignoreUnknownCharacters)!
    static let srv = Data(base64Encoded: """
        MIIDbzCCAlegAwIBAgIUF/egE79MfV/AxAGI9h9sn4L3lOMwDQYJKoZIhvcNAQELBQAwGzEZMBcG
        A1UEAwwQWENoYXQgRml4dHVyZSBDQTAeFw0yNjA5MjcxMjE5NDNaFw0yODEyMDUxMjE5NDNaMBwx
        GjAYBgNVBAMMEWhvc3QucHJvdmlkZXIubmV0MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKC
        AQEAzm/UQXzQSqNmtIf93Q4e0JjpYnQ3rX9cIgIfIIb5iJ9j4Ese8HYM34MtkIgavedSAJHbgXet
        8+6xkY53liH8phJhQBgtGO8ujk3QESza+miLTusxg0gE7Zc5Ky/UOtzyI4tKP4wALZ9E9e9Z97XL
        u1WsCJ9/a5asbsKChb7485YNVM1dqqQCenAafVxZ9j3LzOW6NTkpgtyqOb1hPvNTJylxzPaNcpmr
        TYlpoIQeRQeiyg22p7S0rhd3j8sIF2OTGZiaSlKf98Fnzqi23zGRA+p7rF37Nf4y1cOt6tmf9L3N
        wZJRvI6NxqL3AroKCcHvPx7/dsV+xPcHLE213tintQIDAQABo4GpMIGmMEQGA1UdEQQ9MDuCEWhv
        c3QucHJvdmlkZXIubmV0oCYGCCsGAQUFBwgHoBoWGF94bXBwLWNsaWVudC5leGFtcGxlLm9yZzAT
        BgNVHSUEDDAKBggrBgEFBQcDATAJBgNVHRMEAjAAMB0GA1UdDgQWBBSa/oqgtLgwE3wglSa0Ss7w
        HzY8rTAfBgNVHSMEGDAWgBRuAxFGRw9G9l3dcjpNKI1RHHH77TANBgkqhkiG9w0BAQsFAAOCAQEA
        Mf1PIuzFu6mcB+tvrgHnDVyFaiGMZwEYHnOKeHhDfzupos1iVoeWeRJkoQ/gdRMv16gijUyGlCMx
        JeewIBICxRho+hMsqt/Xmfm/ikSQD51SIo594BvH6Sf4t0P/Pkt8Evx5FNsD9kovkKjM+v/Krl4F
        cpboEr2j95/qr2TY87XxS7Z0+EX2VHwwHmVGKoRyc4D034CTpf0Ggp7WwloJthb/HpXUkB59pPRv
        MZiYIEN8mZwkFQ/QUOyi42L30ziThOiNqUmpwYxs+Bzx5fobJgGhnnw2V7Ina+L2VtkzaDJl2v2l
        jvywh/MNLjrLWrEi1I7doYYR8ZeZDNk4XZUQ7g==
        """, options: .ignoreUnknownCharacters)!
    static let xmppaddr = Data(base64Encoded: """
        MIIDYjCCAkqgAwIBAgIUF/egE79MfV/AxAGI9h9sn4L3lOQwDQYJKoZIhvcNAQELBQAwGzEZMBcG
        A1UEAwwQWENoYXQgRml4dHVyZSBDQTAeFw0yNjA5MjcxMjE5NDNaFw0yODEyMDUxMjE5NDNaMBwx
        GjAYBgNVBAMMEWhvc3QucHJvdmlkZXIubmV0MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKC
        AQEAuAVkEYTqq12tD2KIZHuRkWJQ3N4q9Mw90g9GeKYQDcXMfqr3h1gawsm5hShX9h6u/c/mmlI6
        wZFcA3uZLY0cuyZif+/BuA08fBem0p9ZNNlRSbEPHbsTI18muMFIJOej9OjEOz+l6MbCuFu/YrLd
        Hy1m7kg4rwsKFeOkh14DgQ0pSOfrajiAHm9HxTxo6SLGPzvwOkvjKHW+32WA88hI8TCc7QJuptp1
        DcBDtVTpsJsCd1OjXDgSMpJG/SWEG5bNGjd7pp92j/LK3J9gzpK3e3dvXpu1A9yRxP+XYgXgg5jH
        c3Xb24NYzsVRRW/+vcgwRcW8RntplWuj0BdZ5TOqiwIDAQABo4GcMIGZMDcGA1UdEQQwMC6CEWhv
        c3QucHJvdmlkZXIubmV0oBkGCCsGAQUFBwgFoA0MC2V4YW1wbGUub3JnMBMGA1UdJQQMMAoGCCsG
        AQUFBwMBMAkGA1UdEwQCMAAwHQYDVR0OBBYEFGN/MxmTfApG/xNrjgk1nCHxVjPwMB8GA1UdIwQY
        MBaAFG4DEUZHD0b2Xd1yOk0ojVEccfvtMA0GCSqGSIb3DQEBCwUAA4IBAQCBS2eunykdwVLvTZoA
        eC0VFb4gUzV1KEDlYqhbpoksdciL7yyL0EO+A8yaBTs2qi7C6ZEPbIvfaGjhJs/A+dbRJ/40kB2R
        ODal6MU2UypimYoTmDbOIIXCEgfxWe6gcFIDPdS/hDBLxuhKN/4krhbXO3sKCnnTl3uTC1r6P6D0
        mL2F5fnEfWm7+UgOBUV5tmQW40zBpUQ4ZpPdaCxV98NCLEsfCQRxj6NIxd3caGTokToN68i2woKq
        Vm9narPgjQ6rhVpk8ALl99b4usaCEU1KsLF5OQEHmytG+vk3C0+eqYBfWIRvtTNfufx/3oubZSvu
        Dy+7BcD3OU/Z1KK3qonN
        """, options: .ignoreUnknownCharacters)!
    static let idn = Data(base64Encoded: """
        MIIDIjCCAgqgAwIBAgIUEDCcKVjYFNPwV6iy4q+fdTgGexowDQYJKoZIhvcNAQELBQAwGzEZMBcG
        A1UEAwwQWENoYXQgRml4dHVyZSBDQTAeFw0yNjA5MjcxMjAwMDBaFw0yODEyMDUxMjAwMDBaMBwx
        GjAYBgNVBAMMEWhvc3QucHJvdmlkZXIubmV0MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKC
        AQEAs3qu0KXnW7eWfEp9i0msYdPbAMIxa1soxKCLQToAiLeTwifTnBNrIdlMDUL9CB5BhMOVeLwR
        c3819O0k/LQrnauCUMu/UJ/8FPKGsVehqxb/OhqGMHtLUwaoIVP5Y4aH6I7C7FMiu6emmJcfgZ1d
        pkVaM8pt+rZKyxFyeNoM4ax05LhwkBZjLqJ5fRAFZhxYMUeCP69RUzO8ZKfNYWhm9vQGX1W1bYVK
        1YLTtJExF1zlup3Lz9jADMPcWxwj2Pb+AoEqAY8xua1ShGMUxmOEuK2OkhhDDqHc8OYaKwMuXo0G
        AkRXVqBSoh7dlD5MrlGHnUPCTFw0lkcNTDuIdXBhEwIDAQABo10wWzA5BgNVHREEMjAwghFob3N0
        LnByb3ZpZGVyLm5ldKAbBggrBgEFBQcIBaAPDA1jYWbDqS5leGFtcGxlMBMGA1UdJQQMMAoGCCsG
        AQUFBwMBMAkGA1UdEwQCMAAwDQYJKoZIhvcNAQELBQADggEBAHKs19M++quS78HOllveWxOW6QMd
        SwMNiY9i1MZLwNlv6MKJIecSDWb/YfBj5J/cE4CSYQ9up5z6+H1Lryll80/qR9SCffxScc47Mv7N
        qpJPCKGvhnemyXyBnrL+0Mn4xtf0HV3wFydO+KcyIreprUFYl3XGVtlaN9E5S797jv6hsYTmarPv
        n5GjTzLFCyGweGNc/pehxJsa9SXdrTn2Xb9fahEYXl+4Nm69Y3eefH1nemu27tz3z2aHwoxLN8ky
        ZNcNSPIL2osIF1mW9iZOhuSMw0gZauZySvptglMKw7QBKOqyvzD+b0UZndfPHszd/vXhNgTZCgmu
        7uuvZIHdvfo=
        """, options: .ignoreUnknownCharacters)!
    static let dns = Data(base64Encoded: """
        MIIDPzCCAiegAwIBAgIUF/egE79MfV/AxAGI9h9sn4L3lOYwDQYJKoZIhvcNAQELBQAwGzEZMBcG
        A1UEAwwQWENoYXQgRml4dHVyZSBDQTAeFw0yNjA5MjcxMjE5NDNaFw0yODEyMDUxMjE5NDNaMBwx
        GjAYBgNVBAMMEWhvc3QucHJvdmlkZXIubmV0MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKC
        AQEAufweFvCPns0JTzTjsV4XBrd6EbftQOeX5z1gOFPPgetwdfLgKOVE8eiCXHLu/UApzIEiBbCq
        MHvOCfUfrk+Pws6TnCn2cEzzIiYzsQYrOA5auUjyRp2dAN/VLmwu/Vg9KCuWdzS9zySB/czqdr3V
        o3NzHiDfv9zGfahG0YalqqA08GnM87jPc8fIA9cQfQjFVWL4vdCcUg/rSIe312JoBakDqY5X0GzE
        83k2xyTA1ub4t8V2wOFyefWwnPdvJq3X/VzE+wZm27FlNBLHEXAmlXQ/p00lhxbHWpmtgJYhAXqJ
        HuqkMqratc4cMHgbRq/EhJKPbYY7K/uxujlLxeO/UQIDAQABo3oweDAWBgNVHREEDzANggtleGFt
        cGxlLm9yZzATBgNVHSUEDDAKBggrBgEFBQcDATAJBgNVHRMEAjAAMB0GA1UdDgQWBBRwckoghFoT
        K56uGxDJn5vxHIyBzzAfBgNVHSMEGDAWgBRuAxFGRw9G9l3dcjpNKI1RHHH77TANBgkqhkiG9w0B
        AQsFAAOCAQEAVT1XD9lRgpBnkN7pFSNytTX2GKvHtLBmNH7EMivVWampRa1JYrCAHXJfxJcpZXtz
        ugaibVF7xz3dkH0oFv9HHkEPT/xv5xQ7JcrzlgKBWDZxiLvihTEyHpftSjCEseaF+SlbtKxl6SnS
        GoeCGsfhrS7lkGtHs6+S7U8penLSnY56huZFDS4mrO54+L2O14kaSanVk1mY4ZELjW9hJpsomaGP
        99NiNYJjoKULV070e4NIQQPP0XhIgtFQR4IGvrsrVC5//lblRRmpcc+FrNGEPQCKSh3l3+E+UFkn
        YuJ3A903RI5LvNCCpiuX6i7Fw4Fyzx+dtGJRq8L34imVG8D5Cw==
        """, options: .ignoreUnknownCharacters)!
    static let none = Data(base64Encoded: """
        MIIDRjCCAi6gAwIBAgIUF/egE79MfV/AxAGI9h9sn4L3lOcwDQYJKoZIhvcNAQELBQAwGzEZMBcG
        A1UEAwwQWENoYXQgRml4dHVyZSBDQTAeFw0yNjA5MjcxMjE5NDNaFw0yODEyMDUxMjE5NDNaMBwx
        GjAYBgNVBAMMEWhvc3QucHJvdmlkZXIubmV0MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKC
        AQEAyaTGWt6dULZ1Q58lkvUFq2a0OvWBDtO5A2rTNx7KbgRp5DfLEBw/kbWGIkOB5b96IjFVN4oW
        M7djn5OlNPT4OhkzhV7voRSTdPlt7+NpptHdFBe7RZJtoYlfejKXvEqGC6yyOE970KenqZFgG8XM
        IKkjBCGselTCohBtp8hvVP4qNeTEjZRvbbppVm88U716IR9ISyQ6Nccb3tT27/Ir6BjtBQFMP2mr
        TD/p7PC3lp6EK3u8l2z0sPi7WCMkSUi40gvTmzO9TtTGHINDZtrYGyR8rHjr+a8DOw1KjGdyUu0K
        ls7zj3bfGj8jsfv8NeFyouJyR7+6APYpYYA4NVTmzQIDAQABo4GAMH4wHAYDVR0RBBUwE4IRaG9z
        dC5wcm92aWRlci5uZXQwEwYDVR0lBAwwCgYIKwYBBQUHAwEwCQYDVR0TBAIwADAdBgNVHQ4EFgQU
        /zB4iqS+adfK4nZnnK9jAWOq0yYwHwYDVR0jBBgwFoAUbgMRRkcPRvZd3XI6TSiNURxx++0wDQYJ
        KoZIhvcNAQELBQADggEBALd66ztYe9Kb+7rlpHnowmptlE/uRBj2zVGa6pyCbDubibQeKm1rBQPB
        NkPd2EYvi/AXInvNMHMJno45L6BzD3hcjdS26VlcMHGMuS1Ab4awWwL3/qd86GlbbITnU6eKprKs
        W5/UzUi0/tomVM6CJfhoPtrvO+JLBl24sLY1DJxNLxoXX4TQsfIKXcUVPa05w/IPS6pI04FwhpDg
        BKb0TmN/dgkpQGgTHOo947NDzatJ/GO5S9AXE+Vzxyzn68/GiEtm9kNKDMYkF4uTJCGtUcHK84JV
        xbd1Qsb471SC3CSN+hQ/Ctqf2NbyQzxuveyyqAwKGMdRv/AfBunQasd0swU=
        """, options: .ignoreUnknownCharacters)!
}
