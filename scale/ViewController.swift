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
    private var peripheral: CBPeripheral?
    private var service: CBService?
    private var characteristic: CBCharacteristic?

    var device: HKDevice? {
        if let peripheral = peripheral {
            return HKDevice(name: peripheral.name, manufacturer: nil, model: nil, hardwareVersion: nil, firmwareVersion: nil, softwareVersion: nil, localIdentifier: peripheral.identifier.uuidString, udiDeviceIdentifier: nil)
        } else {
            return nil
        }
    }

    private(set) var weight: (kg: Double, timestamp: Date, repeatCount: Int)?

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
                central.scanForPeripherals(withServices: [serviceUUID])
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        if self.peripheral == nil {
            central.stopScan()
            self.peripheral = peripheral
            peripheral.delegate = self
            central.connect(peripheral)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([serviceUUID])
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) {
            self.service = service
            peripheral.discoverCharacteristics([characteristicUUID], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let characteristic = service.characteristics?.first(where: { $0.uuid == characteristicUUID }) {
            self.characteristic = characteristic
            peripheral.setNotifyValue(true, for: characteristic)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let reader = DataReader(data: characteristic.value) else {
            return
        }
 
        let flags = reader.read16()

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
        print(rawWeight)

        let kg: Double
        if (flags & 1) != 0 {
            kg = Double(rawWeight) * 0.00453592
        } else {
            kg = Double(rawWeight) * 0.005
        }

        let repeatCount = (self.weight?.kg == kg) ? (self.weight!.repeatCount + 1) : 0

        self.weight = (kg: kg, timestamp: Date(), repeatCount: repeatCount)

        delegate?.scalesDidChangeState(self)
    }
}

class ViewController: UIViewController, ScalesDelegate {

    let scales = Scales()
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
        if let weight = scales.weight?.0 {
            weightLabel?.text = String(format: "%.01f", weight)
            saveButton.isEnabled = true
        } else {
            weightLabel?.text = "--"
            saveButton.isEnabled = true
        }
    }

    @IBAction func logWeight() {
        guard let weight = scales.weight else {
            return
        }

        let weightType = HKObjectType.quantityType(forIdentifier: .bodyMass)!
        let weightQuantity = HKQuantity(unit: HKUnit.gram(), doubleValue: weight.kg * 1000)
        let weightSample = HKQuantitySample(type: weightType, quantity: weightQuantity, start: weight.timestamp, end: weight.timestamp, device: scales.device, metadata: nil)

        healthStore.requestAuthorization(toShare: [weightType], read: nil) { ok, _ in
            healthStore.save(weightSample) { ok, err in
            }
        }
    }
}

