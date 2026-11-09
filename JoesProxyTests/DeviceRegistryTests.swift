import XCTest
@testable import JoesProxy

final class DeviceRegistryTests: XCTestCase {
    private var testDefaults: UserDefaults!
    private var aliasStore: DeviceAliasStore!
    private var registry: DeviceRegistry!

    override func setUp() {
        super.setUp()
        testDefaults = UserDefaults(suiteName: "DeviceRegistryTestsSuite")
        testDefaults.removePersistentDomain(forName: "DeviceRegistryTestsSuite")
        aliasStore = DeviceAliasStore(defaults: testDefaults)
        registry = DeviceRegistry(aliasStore: aliasStore)
    }

    override func tearDown() {
        testDefaults.removePersistentDomain(forName: "DeviceRegistryTestsSuite")
        super.tearDown()
    }

    func testLoopbackClassification() {
        XCTAssertTrue(DiscoveredDevice.checkIsLoopback("127.0.0.1"))
        XCTAssertTrue(DiscoveredDevice.checkIsLoopback("::1"))
        XCTAssertTrue(DiscoveredDevice.checkIsLoopback("localhost"))
        XCTAssertFalse(DiscoveredDevice.checkIsLoopback("192.168.1.50"))
        XCTAssertFalse(DiscoveredDevice.checkIsLoopback("10.0.0.2"))
    }

    func testRecordClientConnectionCreatesAndUpdates() async {
        let d1 = await registry.recordClientConnection(ipAddress: "192.168.1.100")
        XCTAssertEqual(d1?.ipAddress, "192.168.1.100")
        XCTAssertEqual(d1?.sessionCount, 1)
        XCTAssertEqual(d1?.isLoopback, false)

        let d2 = await registry.recordClientConnection(ipAddress: "192.168.1.100")
        XCTAssertEqual(d2?.sessionCount, 2)

        let devices = await registry.discoveredDevices()
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices.first?.ipAddress, "192.168.1.100")
        XCTAssertEqual(devices.first?.sessionCount, 2)
    }

    func testDeviceAliasPersistence() async {
        _ = await registry.recordClientConnection(ipAddress: "192.168.1.42")
        let updated = await registry.setDeviceAlias(ipAddress: "192.168.1.42", alias: "Living Room Apple TV")
        XCTAssertNotNil(updated)
        XCTAssertEqual(updated?.customAlias, "Living Room Apple TV")
        XCTAssertEqual(updated?.displayName, "Living Room Apple TV")

        let stored = await aliasStore.getAlias(for: "192.168.1.42")
        XCTAssertEqual(stored, "Living Room Apple TV")

        // New registry instance using same store sees alias
        let freshRegistry = DeviceRegistry(aliasStore: aliasStore)
        let d = await freshRegistry.recordClientConnection(ipAddress: "192.168.1.42")
        XCTAssertEqual(d?.customAlias, "Living Room Apple TV")
        XCTAssertEqual(d?.displayName, "Living Room Apple TV")
    }

    func testLoopbackDisplayName() async {
        let loopback = await registry.recordClientConnection(ipAddress: "127.0.0.1")
        XCTAssertEqual(loopback?.isLoopback, true)
        XCTAssertEqual(loopback?.displayName, "This Mac (127.0.0.1)")

        // Setting an alias overrides default loopback display name
        _ = await registry.setDeviceAlias(ipAddress: "127.0.0.1", alias: "Primary Dev Machine")
        let renamed = await registry.getDevice(ipAddress: "127.0.0.1")
        XCTAssertEqual(renamed?.displayName, "Primary Dev Machine")
    }

    func testDeviceSorting() async {
        _ = await registry.recordClientConnection(ipAddress: "192.168.1.10", timestamp: Date(timeIntervalSince1970: 100))
        _ = await registry.recordClientConnection(ipAddress: "192.168.1.20", timestamp: Date(timeIntervalSince1970: 200))
        _ = await registry.recordClientConnection(ipAddress: "127.0.0.1", timestamp: Date(timeIntervalSince1970: 50))

        let sorted = await registry.discoveredDevices()
        XCTAssertEqual(sorted.count, 3)
        // Loopback should always be first
        XCTAssertEqual(sorted[0].ipAddress, "127.0.0.1")
        // Then by last seen descending
        XCTAssertEqual(sorted[1].ipAddress, "192.168.1.20")
        XCTAssertEqual(sorted[2].ipAddress, "192.168.1.10")
    }
}
