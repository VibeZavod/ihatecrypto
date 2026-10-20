// Off Apple, URLSession and friends live in FoundationNetworking; every module that imports WalletCore sees them here.
#if canImport(FoundationNetworking)
@_exported import FoundationNetworking
#endif
