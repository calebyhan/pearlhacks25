import CryptoKit
import Foundation

func generateTURNCredentials(secret: String) -> (username: String, credential: String) {
    let expiry = Int(Date().timeIntervalSince1970) + 3600  // 1 hour
    let username = "\(expiry):visual911user"
    let key = SymmetricKey(data: Data(secret.utf8))
    let mac = HMAC<Insecure.SHA1>.authenticationCode(for: Data(username.utf8), using: key)
    let credential = Data(mac).base64EncodedString()
    return (username, credential)
}

// Convenience accessors used by WebRTCManager
func generatedTURNUsername() -> String {
    generateTURNCredentials(secret: "db2669070d85d65b473452eeec7c2522576b3e03cd77efc169b5e52a99270df0").username
}

func generatedTURNCredential() -> String {
    generateTURNCredentials(secret: "db2669070d85d65b473452eeec7c2522576b3e03cd77efc169b5e52a99270df0").credential
}
