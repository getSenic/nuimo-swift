//
//  NuimoController.swift
//  Nuimo
//
//  Created by Lars Blumberg on 9/23/15.
//  Copyright © 2015 Senic. All rights reserved.
//
//  This software may be modified and distributed under the terms
//  of the MIT license.  See the LICENSE file for details.

import CoreBluetooth

// Represents a bluetooth low energy (BLE) Nuimo controller
public class NuimoBluetoothController: NSObject, NuimoController, CBPeripheralDelegate {
    public let uuid: String
    public var delegate: NuimoControllerDelegate?
    
    public var state: NuimoConnectionState { get{ return self.peripheral.state.nuimoConnectionState } }
    public var batteryLevel: Int = -1 { didSet { if self.batteryLevel != oldValue { delegate?.nuimoController(self, didUpdateBatteryLevel: self.batteryLevel) } } }
    
    private let peripheral: CBPeripheral
    private let centralManager: CBCentralManager
    private var ledMatrixCharacteristic: CBCharacteristic?
    private var currentMatrixName: String?
    private var isWaitingForLedMatrixWriteResponse: Bool = false
    private var writeMatrixOnWriteResponseReceived: Bool = false
    private var writeMatrixResponseTimeoutTimer: NSTimer?
    private var clearMatrixTimer: NSTimer?
    
    public init(centralManager: CBCentralManager, uuid: String, peripheral: CBPeripheral) {
        self.centralManager = centralManager
        self.uuid = uuid
        self.peripheral = peripheral
        super.init()
        peripheral.delegate = self
    }
    
    public func connect() {
        if peripheral.state == .Disconnected {
            centralManager.connectPeripheral(peripheral, options: nil)
            delegate?.nuimoControllerDidStartConnecting(self)
        }
    }
    
    internal func didConnect() {
        isWaitingForLedMatrixWriteResponse = false
        writeMatrixOnWriteResponseReceived = false
        // Discover bluetooth services
        peripheral.discoverServices(nuimoServiceUUIDs)
        delegate?.nuimoControllerDidConnect(self)
    }
    
    internal func didFailToConnect() {
        delegate?.nuimoControllerDidFailToConnect(self)
    }
    
    public func disconnect() {
        if peripheral.state != .Connected {
            return
        }
        centralManager.cancelPeripheralConnection(peripheral)
    }
    
    internal func didDisconnect() {
        peripheral.delegate = nil
        ledMatrixCharacteristic = nil
        delegate?.nuimoControllerDidDisconnect(self)
    }
    
    internal func invalidate() {
        peripheral.delegate = nil
        delegate?.nuimoControllerDidInvalidate(self)
    }
    
    //MARK: - CBPeripheralDelegate
    
    @objc public func peripheral(peripheral: CBPeripheral, didDiscoverServices error: NSError?) {
        peripheral.services?
            .flatMap{ ($0, charactericUUIDsForServiceUUID[$0.UUID]) }
            .forEach{ peripheral.discoverCharacteristics($0.1, forService: $0.0) }
    }
    
    @objc public func peripheral(peripheral: CBPeripheral, didDiscoverCharacteristicsForService service: CBService, error: NSError?) {
        service.characteristics?.forEach{ characteristic in
            switch characteristic.UUID {
            case kBatteryCharacteristicUUID:
                peripheral.readValueForCharacteristic(characteristic)
            case kLEDMatrixCharacteristicUUID:
                ledMatrixCharacteristic = characteristic
                delegate?.nuimoControllerDidDiscoverMatrixService(self)
            default:
                break
            }
            if characteristicNotificationUUIDs.contains(characteristic.UUID) {
                peripheral.setNotifyValue(true, forCharacteristic: characteristic)
            }
        }
    }
    
    @objc public func peripheral(peripheral: CBPeripheral, didUpdateValueForCharacteristic characteristic: CBCharacteristic, error: NSError?) {
        guard let data = characteristic.value else {
            return
        }
        
        switch characteristic.UUID {
        case kBatteryCharacteristicUUID:
            batteryLevel = Int(UnsafePointer<UInt8>(data.bytes).memory)
        default:
            if let event = characteristic.nuimoGestureEvent() {
                delegate?.nuimoController(self, didReceiveGestureEvent: event)
            }
        }
    }
    
    @objc public func peripheral(peripheral: CBPeripheral, didUpdateNotificationStateForCharacteristic characteristic: CBCharacteristic, error: NSError?) {
        // Nothing to do here
    }
    
    @objc public func peripheral(peripheral: CBPeripheral, didWriteValueForCharacteristic characteristic: CBCharacteristic, error: NSError?) {
        if characteristic.UUID == kLEDMatrixCharacteristicUUID {
            didRetrieveMatrixWriteResponse()
        }
    }
    
    //MARK: - LED matrix writing
    
    public func writeMatrix(matrixName: String) {
        // Do not send same matrix again if already shown
        if matrixName == currentMatrixName {
            return
        }
        currentMatrixName = matrixName
        
        // Send matrix later when the write response from previous write request is not yet received
        if isWaitingForLedMatrixWriteResponse {
            writeMatrixOnWriteResponseReceived = true
        } else {
            writeMatrixNow(matrixName)
        }
    }
    
    public func writeBarMatrix(percent: Int){
        let suffix = min(max(percent / 10, 1), 9)
        writeMatrix("bar_\(suffix)")
    }
    
    private func writeMatrixNow(matrixName: String) {
        assert(!isWaitingForLedMatrixWriteResponse, "Cannot write matrix now, response from previous write request not yet received")
        
        let matrixData = NuimoMatrixManager.sharedManager.matrixData(matrixName)
        guard let ledMatrixCharacteristic = ledMatrixCharacteristic else {
            return
        }
        peripheral.writeValue(matrixData, forCharacteristic: ledMatrixCharacteristic, type: .WithResponse)
        isWaitingForLedMatrixWriteResponse = true
        
        // When the matrix write response is not retrieved within 100ms we assume the response to have timed out
        writeMatrixResponseTimeoutTimer?.invalidate()
        writeMatrixResponseTimeoutTimer = NSTimer.scheduledTimerWithTimeInterval(0.1, target: self, selector: "didRetrieveMatrixWriteResponse", userInfo: nil, repeats: false)
        
        // Clear the matrix after a timeout
        clearMatrixTimer?.invalidate()
        if shouldClearMatrixAfterTimeout && matrixName != "empty" {
            clearMatrixTimer = NSTimer.scheduledTimerWithTimeInterval(3.0, target: self, selector: "clearMatrix", userInfo: nil, repeats: false)
        }
    }
    
    func didRetrieveMatrixWriteResponse() {
        isWaitingForLedMatrixWriteResponse = false
        writeMatrixResponseTimeoutTimer?.invalidate()
        
        // Write next matrix if any
        if writeMatrixOnWriteResponseReceived {
            writeMatrixOnWriteResponseReceived = false
            guard let matrixName = currentMatrixName else {
                assertionFailure("No matrix to write")
                return
            }
            writeMatrixNow(matrixName)
        }
    }
    
    func clearMatrix() {
        writeMatrix("empty")
    }
}

private let shouldClearMatrixAfterTimeout = false

private extension CBPeripheralState {
    var nuimoConnectionState: NuimoConnectionState {
        switch self {
        case .Connecting:    return .Connecting
        case .Connected:     return .Connected
        case .Disconnecting: return .Disconnecting
        case .Disconnected:  return .Disconnected
        }
    }
}

private extension CBCharacteristic {
    func nuimoGestureEvent() -> NuimoGestureEvent? {
        guard let data = value else { return nil }
        
        switch UUID {
        case kSensorFlyCharacteristicUUID:      return NuimoGestureEvent(gattFlyData: data)
        case kSensorTouchCharacteristicUUID:    return NuimoGestureEvent(gattTouchData: data)
        case kSensorRotationCharacteristicUUID: return NuimoGestureEvent(gattRotationData: data)
        case kSensorButtonCharacteristicUUID:   return NuimoGestureEvent(gattButtonData: data)
        default: return nil
        }
    }
}

private let kBatteryServiceUUID                  = CBUUID(string: "180F")
private let kBatteryCharacteristicUUID           = CBUUID(string: "2A19")
private let kDeviceInformationServiceUUID        = CBUUID(string: "180A")
private let kDeviceInformationCharacteristicUUID = CBUUID(string: "2A29")
private let kLEDMatrixServiceUUID                = CBUUID(string: "F29B1523-CB19-40F3-BE5C-7241ECB82FD1")
private let kLEDMatrixCharacteristicUUID         = CBUUID(string: "F29B1524-CB19-40F3-BE5C-7241ECB82FD1")
private let kSensorServiceUUID                   = CBUUID(string: "F29B1525-CB19-40F3-BE5C-7241ECB82FD2")
private let kSensorFlyCharacteristicUUID         = CBUUID(string: "F29B1526-CB19-40F3-BE5C-7241ECB82FD2")
private let kSensorTouchCharacteristicUUID       = CBUUID(string: "F29B1527-CB19-40F3-BE5C-7241ECB82FD2")
private let kSensorRotationCharacteristicUUID    = CBUUID(string: "F29B1528-CB19-40F3-BE5C-7241ECB82FD2")
private let kSensorButtonCharacteristicUUID      = CBUUID(string: "F29B1529-CB19-40F3-BE5C-7241ECB82FD2")

internal let nuimoServiceUUIDs: [CBUUID] = [
    kBatteryServiceUUID,
    kDeviceInformationServiceUUID,
    kLEDMatrixServiceUUID,
    kSensorServiceUUID
]

private let charactericUUIDsForServiceUUID = [
    kBatteryServiceUUID: [kBatteryCharacteristicUUID],
    kDeviceInformationServiceUUID: [kDeviceInformationCharacteristicUUID],
    kLEDMatrixServiceUUID: [kLEDMatrixCharacteristicUUID],
    kSensorServiceUUID: [
        kSensorFlyCharacteristicUUID,
        kSensorTouchCharacteristicUUID,
        kSensorRotationCharacteristicUUID,
        kSensorButtonCharacteristicUUID
    ]
]

private let characteristicNotificationUUIDs = [
    kBatteryCharacteristicUUID,
    kSensorFlyCharacteristicUUID,
    kSensorTouchCharacteristicUUID,
    kSensorRotationCharacteristicUUID,
    kSensorButtonCharacteristicUUID
]
