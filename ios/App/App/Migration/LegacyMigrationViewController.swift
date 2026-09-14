import Capacitor
import Foundation

final class LegacyMigrationViewController: CAPBridgeViewController {
    let inventoryProbe: LegacyMigrationInventoryProbe

    init(inventoryProbe: LegacyMigrationInventoryProbe = LegacyMigrationInventoryProbe()) {
        self.inventoryProbe = inventoryProbe
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        inventoryProbe = LegacyMigrationInventoryProbe()
        super.init(coder: coder)
    }

    override func instanceDescriptor() -> InstanceDescriptor {
        let descriptor = super.instanceDescriptor()
        descriptor.appStartPath = "legacy-migration.html"
        return descriptor
    }

    override func capacitorDidLoad() {
        super.capacitorDidLoad()
        bridge?.registerPluginInstance(LegacyMigrationPlugin(receiver: inventoryProbe))
    }
}
