import Foundation
import XCTest
@testable import LostFoundCore

final class ServerAddressTests: XCTestCase {
    func testNormalizesOriginAndAllowsHTTPSNetworkServers() throws {
        XCTAssertEqual(try ServerAddress.parse("  HTTPS://School.local:8443/ \n").absoluteString,
                       "https://school.local:8443")
        XCTAssertEqual(try ServerAddress.parse("https://192.168.1.12").absoluteString,
                       "https://192.168.1.12")
        XCTAssertEqual(try ServerAddress.parse("https://[2001:db8::1]:8443/").port, 8443)
    }

    func testHTTPIsLimitedToValidLoopbackAddresses() throws {
        for address in ["http://localhost:8080", "http://127.0.0.1:8080/", "http://127.255.2.3",
                        "http://[::1]:8080", "http://[0:0:0:0:0:0:0:1]:8080"] {
            XCTAssertNoThrow(try ServerAddress.parse(address), address)
        }
        for address in ["http://192.168.1.1:8080", "http://school.local", "http://[::2]",
                        "http://localhost.evil.test", "http://127.999.0.1", "http://[0:1]"] {
            XCTAssertThrowsError(try ServerAddress.parse(address), address)
        }
    }

    func testRejectsCredentialsPathsQueryFragmentsAndMalformedOrigins() {
        let invalid = ["", "localhost:8080", "ftp://localhost", "https://", "https://user:pass@school.local",
                       "https://@school.local", "https://school.local/api", "https://school.local//",
                       "https://school.local/%2F", "https://school.local?", "https://school.local#",
                       "https://school.local?token=abc", "https://school.local/#photo", "https://bad host.local",
                       "https://a..local", "https://-host.local", "https://[::::]", "https://256.1.1.1"]
        for address in invalid {
            XCTAssertThrowsError(try ServerAddress.parse(address), address)
        }
    }

    func testRejectsInvalidPorts() {
        for port in ["", "0", "-1", "65536", "abc", "999999999999999999999999"] {
            XCTAssertThrowsError(try ServerAddress.parse("https://school.local:\(port)"), port)
        }
        XCTAssertNoThrow(try ServerAddress.parse("https://school.local:65535"))
    }
}
