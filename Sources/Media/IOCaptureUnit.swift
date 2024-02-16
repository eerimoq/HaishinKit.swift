import AVFoundation
import Foundation

protocol IOCaptureUnit {
    associatedtype Output: AVCaptureOutput

    var input: AVCaptureInput? { get }
    var output: Output? { get }
    var connection: AVCaptureConnection? { get }
}

extension IOCaptureUnit {
    func attachSession(_ session: AVCaptureSession?) {
        guard let session else {
            logger.error("No session to attach to")
            return
        }
        if let connection {
            if let input, session.canAddInput(input) {
                session.addInputWithNoConnections(input)
            } else {
                logger.error("Cannot add input with no connections")
            }
            if let output, session.canAddOutput(output) {
                session.addOutputWithNoConnections(output)
            } else {
                logger.error("Cannot add output with no connections")
            }
            if session.canAddConnection(connection) {
                session.addConnection(connection)
            } else {
                logger.error("Cannot add connection")
            }
        } else {
            if let input, session.canAddInput(input) {
                session.addInput(input)
            } else {
                logger.error("Cannot add input")
            }
            if let output, session.canAddOutput(output) {
                session.addOutput(output)
            } else {
                logger.error("Cannot add output")
            }
        }
        session.automaticallyConfiguresCaptureDeviceForWideColor = false
    }

    func detachSession(_ session: AVCaptureSession?) {
        guard let session else {
            logger.error("No session to detach from")
            return
        }
        if let connection {
            if output?.connections.contains(connection) == true {
                session.removeConnection(connection)
            }
        }
        if let input, session.inputs.contains(input) {
            session.removeInput(input)
        }
        if let output, session.outputs.contains(output) {
            session.removeOutput(output)
        }
    }
}

/// An object that provides the interface to control the AVCaptureDevice's transport behavior.
public class IOVideoCaptureUnit: IOCaptureUnit {
    typealias Output = AVCaptureVideoDataOutput

    /// The current video device object.
    public private(set) var device: AVCaptureDevice?
    var input: AVCaptureInput?
    var output: Output?
    var connection: AVCaptureConnection?

    /// Specifies the videoOrientation indicates whether to rotate the video flowing through the
    /// connection to a given orientation.
    public var videoOrientation: AVCaptureVideoOrientation = .portrait {
        didSet {
            output?.connections.filter { $0.isVideoOrientationSupported }.forEach {
                $0.videoOrientation = videoOrientation
            }
        }
    }

    /// Spcifies the video mirroed indicates whether the video flowing through the connection should be
    /// mirrored about its vertical axis.
    public var isVideoMirrored = false {
        didSet {
            output?.connections.filter { $0.isVideoMirroringSupported }.forEach {
                $0.isVideoMirrored = isVideoMirrored
            }
        }
    }

    /// Specifies the preferredVideoStabilizationMode most appropriate for use with the connection.
    public var preferredVideoStabilizationMode: AVCaptureVideoStabilizationMode = .off {
        didSet {
            output?.connections.filter { $0.isVideoStabilizationSupported }.forEach {
                $0.preferredVideoStabilizationMode = preferredVideoStabilizationMode
            }
        }
    }

    func setFrameRate(frameRate: Float64, colorSpace: AVCaptureColorSpace) {
        guard let device else {
            return
        }
        guard let format = device.findVideoFormat(
            width: device.activeFormat.formatDescription.dimensions.width,
            height: device.activeFormat.formatDescription.dimensions.height,
            frameRate: frameRate,
            colorSpace: colorSpace
        ) else {
            logger.info("No matching video format found")
            return
        }
        logger.info("Selected video format: \(format)")
        do {
            try device.lockForConfiguration()
            if device.activeFormat != format {
                device.activeFormat = format
            }
            device.activeColorSpace = colorSpace
            device.activeVideoMinFrameDuration = CMTime(
                value: 100,
                timescale: CMTimeScale(100 * frameRate)
            )
            device.activeVideoMaxFrameDuration = CMTime(
                value: 100,
                timescale: CMTimeScale(100 * frameRate)
            )
            device.unlockForConfiguration()
        } catch {
            logger.error("while locking device for fps:", error)
        }
    }

    func attachDevice(_ device: AVCaptureDevice?, videoUnit: IOVideoUnit) throws {
        setSampleBufferDelegate(nil)
        detachSession(videoUnit.mixer?.videoSession)
        self.device = device
        guard let device else {
            input = nil
            output = nil
            connection = nil
            return
        }
        input = try AVCaptureDeviceInput(device: device)
        output = AVCaptureVideoDataOutput()
        output?.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
        if let output, let port = input?.ports
            .first(where: {
                $0.mediaType == .video && $0.sourceDeviceType == device.deviceType && $0
                    .sourceDevicePosition == device.position
            })
        {
            connection = AVCaptureConnection(inputPorts: [port], output: output)
        } else {
            connection = nil
        }
        attachSession(videoUnit.mixer?.videoSession)
        output?.connections.forEach {
            if $0.isVideoMirroringSupported {
                $0.isVideoMirrored = isVideoMirrored
            }
            if $0.isVideoOrientationSupported {
                $0.videoOrientation = videoOrientation
            }
            if $0.isVideoStabilizationSupported {
                $0.preferredVideoStabilizationMode = preferredVideoStabilizationMode
            }
        }
        setSampleBufferDelegate(videoUnit)
    }

    func setTorchMode(_ torchMode: AVCaptureDevice.TorchMode) {
        guard let device, device.isTorchModeSupported(torchMode) else {
            return
        }
        do {
            try device.lockForConfiguration()
            device.torchMode = torchMode
            device.unlockForConfiguration()
        } catch {
            logger.error("while setting torch:", error)
        }
    }

    func setSampleBufferDelegate(_ videoUnit: IOVideoUnit?) {
        if let videoUnit {
            videoOrientation = videoUnit.videoOrientation
            setFrameRate(frameRate: videoUnit.frameRate, colorSpace: videoUnit.colorSpace)
        }
        output?.setSampleBufferDelegate(videoUnit, queue: videoUnit?.lockQueue)
    }
}

class IOAudioCaptureUnit: IOCaptureUnit {
    typealias Output = AVCaptureAudioDataOutput

    private(set) var device: AVCaptureDevice?
    var input: AVCaptureInput?
    var output: Output?
    var connection: AVCaptureConnection?

    func attachDevice(_ device: AVCaptureDevice?, audioUnit: IOAudioUnit) throws {
        setSampleBufferDelegate(nil)
        detachSession(audioUnit.mixer?.audioSession)
        guard let device else {
            self.device = nil
            input = nil
            output = nil
            return
        }
        self.device = device
        input = try AVCaptureDeviceInput(device: device)
        output = AVCaptureAudioDataOutput()
        attachSession(audioUnit.mixer?.audioSession)
        setSampleBufferDelegate(audioUnit)
    }

    func setSampleBufferDelegate(_ audioUnit: IOAudioUnit?) {
        output?.setSampleBufferDelegate(audioUnit, queue: audioUnit?.lockQueue)
    }
}
