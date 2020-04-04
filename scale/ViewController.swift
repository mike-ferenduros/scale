        //
//  ViewController.swift
//  scale
//
//  Created by Michael Ferenduros on 07/03/2018.
//  Copyright © 2018 Michael Ferenduros. All rights reserved.
//

import UIKit
import CoreBluetooth
import HealthKit

let healthStore = HKHealthStore()

protocol ScalesDelegate: class {
    func scalesDidChangeState(_ scales: Scales)
}

class DataReader {
    private let data: Data
    private var cursor = 0
    var remaining: Int { return data.count - cursor }

    init?(data: Data?) {
        guard let data = data else {
            return nil
        }
        self.data = data
    }

    func skip(_ count: Int) {
        cursor += count
    }

    func read8() -> UInt8 {
        assert(remaining >= 1)
        cursor += 1
        return data[cursor-1]
    }

    func read16() -> UInt16 {
        let b0 = read8()
        let b1 = read8()
        return UInt16(b0) | (UInt16(b1) << 8)
    }
}

class Scales : NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {

    weak var delegate: ScalesDelegate?

    let serviceUUID = CBUUID(string: "0x181B")
    let characteristicUUID = CBUUID(string: "0x2A9C")

    private var central: CBCentralManager!

    private var peripheral: CBPeripheral? {
        didSet {
            oldValue?.delegate = nil
            peripheral?.delegate = self
        }
    }

    private var service: CBService?
    private var characteristic: CBCharacteristic?
    
    var saveStatus: String?

    var status: String {
        if let saveStatus = saveStatus {
            return saveStatus
        } else if peripheral == nil {
            return "Looking for scale"
        } else if characteristic == nil {
            return "Connecting"
        } else {
            return peripheral?.name ?? "Connected"
        }
    }

    var device: HKDevice? {
        if let peripheral = peripheral {
            return HKDevice(name: peripheral.name, manufacturer: nil, model: nil, hardwareVersion: nil, firmwareVersion: nil, softwareVersion: nil, localIdentifier: peripheral.identifier.uuidString, udiDeviceIdentifier: nil)
        } else {
            return nil
        }
    }

    private(set) var weight: (kg: Double, timestamp: Date, isFinal: Int)?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
            case .unknown:
                print("CBCentralManager: .unknown")
            case .resetting:
                print("CBCentralManager: .resetting")
            case .unsupported:
                print("CBCentralManager: .unsupported")
            case .unauthorized:
                print("CBCentralManager: .unauthorized")
            case .poweredOff:
                print("CBCentralManager: .poweredOff")
            case .poweredOn:
                print("CBCentralManager: .poweredOn")
                reset()
        }
        delegate?.scalesDidChangeState(self)
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        if self.peripheral == nil {
            central.stopScan()
            self.peripheral = peripheral
            delegate?.scalesDidChangeState(self)

            central.connect(peripheral)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        if peripheral == self.peripheral {
            peripheral.discoverServices([serviceUUID])
        }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        if peripheral == self.peripheral {
            reset()
        }
    }

    func reset() {
        if let peripheral = self.peripheral {
            self.peripheral = nil
            self.service = nil
            self.characteristic = nil
            central.cancelPeripheralConnection(peripheral)
        }
        central.scanForPeripherals(withServices: [serviceUUID])
        delegate?.scalesDidChangeState(self)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if peripheral == self.peripheral {
            reset()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) {
            self.service = service
            peripheral.discoverCharacteristics([characteristicUUID], for: service)
        } else {
            print("Characteristic not found")
            reset()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if service == self.service, let characteristic = service.characteristics?.first(where: { $0.uuid == characteristicUUID }) {
            self.characteristic = characteristic
            peripheral.setNotifyValue(true, for: characteristic)
        } else {
            print("Characteristic not found")
            reset()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic == self.characteristic, let reader = DataReader(data: characteristic.value) else {
            return
        }

        let flags = reader.read16()

        if (flags & (1<<15)) != 0 {
            self.weight = nil
            delegate?.scalesDidChangeState(self)
            return
        }

        guard flags & (1<<10) != 0 else {
            return
        }

        reader.skip(2)
        let skips = [0, 7, 1, 2, 2, 2, 2, 2, 2, 2]
        for bit in skips.indices {
            if (flags & (1 << bit)) != 0 {
                reader.skip(skips[bit])
            }
        }

        let rawWeight = reader.read16()

        let kg: Double
        if (flags & 1) != 0 {
            kg = Double(rawWeight) * 0.00453592
        } else {
            kg = Double(rawWeight) * 0.005
        }

        let final: Int
        if (flags & (1<<13)) != 0 {
            final = (self.weight?.isFinal ?? 0) + 1
        } else {
            final = 0
        }

        self.weight = (kg: kg, timestamp: Date(), isFinal: final)

        delegate?.scalesDidChangeState(self)
    }
}

class ViewController: UIViewController, ScalesDelegate {

    let scales = Scales()
    @IBOutlet var statusLabel: UILabel!
    @IBOutlet var weightLabel: UILabel!
    @IBOutlet var saveButton: UIButton!

    override func viewDidLoad() {
        super.viewDidLoad()
        scales.delegate = self
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }

    func scalesDidChangeState(_ scales: Scales) {
        if let weight = scales.weight {
            weightLabel?.text = String(format: "%.01f", weight.kg)
            saveButton.isEnabled = true
        } else {
            weightLabel?.text = "--"
            saveButton.isEnabled = false
        }
        statusLabel.text = scales.status
    }

    @IBAction func logWeight() {
        guard let weight = scales.weight else {
            return
        }

        let weightType = HKObjectType.quantityType(forIdentifier: .bodyMass)!
        let weightQuantity = HKQuantity(unit: HKUnit.gram(), doubleValue: weight.kg * 1000)
        let weightSample = HKQuantitySample(type: weightType, quantity: weightQuantity, start: weight.timestamp, end: weight.timestamp, device: scales.device, metadata: nil)

        saveButton.isEnabled = false

        healthStore.requestAuthorization(toShare: [weightType], read: nil) { ok, _ in
            healthStore.save(weightSample) { ok, err in
                DispatchQueue.main.async {
                    self.scales.saveStatus = ok ? "Saved 👍" : "Failed 👎"
                    self.statusLabel.text = self.scales.status

                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        self.scales.saveStatus = ok ? "Saved 👍" : "Failed 👎"
                        self.statusLabel.text = self.scales.status
                    }
                }
            }
        }
    }
}

