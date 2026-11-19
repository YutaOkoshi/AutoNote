// Exports one code-signing identity (certificate and private key) as a PKCS#12 file, found by its certificate's
// SHA-1. `security export` can only export every identity of a keychain at once; this exports just the one
// (review L5). The passphrase comes from AUTONOTE_EXPORT_PASSWORD, never from the command line.
//
//   AUTONOTE_EXPORT_PASSWORD=… swift scripts/export-identity.swift <sha1> <out.p12> [<keychain>]
//
// macOS asks once for the keychain password when the key's access list does not include this process.
// Exit codes: 0 written, 1 not found or export failed, 2 usage.
import CryptoKit
import Foundation
import Security

let args = CommandLine.arguments
guard args.count == 3 || args.count == 4,
      let passphrase = ProcessInfo.processInfo.environment["AUTONOTE_EXPORT_PASSWORD"], !passphrase.isEmpty else {
    FileHandle.standardError.write(Data("usage: AUTONOTE_EXPORT_PASSWORD=… swift export-identity.swift <sha1> <out.p12> [<keychain>]\n".utf8))
    exit(2)
}
let wanted = args[1].lowercased()
let out = URL(fileURLWithPath: args[2])

var query: [String: Any] = [kSecClass as String: kSecClassIdentity, kSecMatchLimit as String: kSecMatchLimitAll,
                            kSecReturnRef as String: true]
if args.count == 4 {
    var keychain: SecKeychain?
    guard SecKeychainOpen(args[3], &keychain) == errSecSuccess, let keychain else { exit(1) }
    query[kSecMatchSearchList as String] = [keychain]
}
var found: CFTypeRef?
guard SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess, let identities = found as? [SecIdentity] else {
    FileHandle.standardError.write(Data("no identities\n".utf8))
    exit(1)
}
for identity in identities {
    var certificate: SecCertificate?
    guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate else { continue }
    let der = SecCertificateCopyData(certificate) as Data
    let sha1 = Insecure.SHA1.hash(data: der).map { String(format: "%02x", $0) }.joined()
    guard sha1 == wanted else { continue }
    var parameters = SecItemImportExportKeyParameters()
    parameters.version = UInt32(SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION)
    parameters.passphrase = Unmanaged.passUnretained(passphrase as CFString as AnyObject)
    var data: CFData?
    let status = SecItemExport(identity, .formatPKCS12, [], &parameters, &data)
    guard status == errSecSuccess, let data else {
        FileHandle.standardError.write(Data("export failed (\(status))\n".utf8))
        exit(1)
    }
    guard FileManager.default.createFile(atPath: out.path, contents: data as Data, attributes: [.posixPermissions: 0o600]) else {
        exit(1)
    }
    exit(0)
}
FileHandle.standardError.write(Data("no identity with SHA-1 \(wanted)\n".utf8))
exit(1)
