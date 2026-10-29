import Foundation
import Security

/// Generic-password storage in the login Keychain, readable only on this device.
public struct Keychain: Sendable {
  public let service: String

  public init(service: String) {
    self.service = service
  }

  public func set(_ data: Data, for account: String) throws {
    let query = baseQuery(account)
    let attributes: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if status == errSecItemNotFound {
      status = SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
    }
    guard status == errSecSuccess else { throw KeychainError(status: status) }
  }

  public func get(_ account: String) throws -> Data? {
    var query = baseQuery(account)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw KeychainError(status: status) }
    return result as? Data
  }

  public func delete(_ account: String) throws {
    let status = SecItemDelete(baseQuery(account) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
  }

  private func baseQuery(_ account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }
}

public struct KeychainError: Error, CustomStringConvertible {
  public let status: OSStatus
  public var description: String {
    "Keychain error \(status): \(SecCopyErrorMessageString(status, nil) as String? ?? "unknown")"
  }
}
