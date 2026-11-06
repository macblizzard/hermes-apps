import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class MockProtocol: URLProtocol {
    static var requests: [URLRequest] = []
    static var status = 200
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        let path = request.url!.path
        let body: String
        if path == "/v1/token" { body = "{\"ws_ticket\":\"ticket-\(Self.requests.count)\"}" }
        else if request.httpMethod == "GET" { body = "[{\"device_id\":\"other\",\"name\":\"Phone\",\"platform\":\"ios\",\"revoked\":false}]" }
        else { body = Self.status == 409 ? "{\"detail\":\"device is not revoked\"}" : "{}" }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: path == "/v1/token" ? 200 : Self.status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct TestRunner {
    static func main() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockProtocol.self]
        let service = MacDeviceService(address: PairingAddress(baseURL: "wss://example.test/v1/ws", deviceID: "mine", token: "secret"), session: URLSession(configuration: config))
        let devices = try await service.devices()
        precondition(devices.count == 1 && devices[0].name == "Phone")
        try await service.revoke("other")
        try await service.removeRevoked("other")
        let requests = MockProtocol.requests
        precondition(requests.map { $0.url!.path } == ["/v1/token", "/v1/devices", "/v1/token", "/v1/devices/other", "/v1/token", "/v1/devices/other/revoked"])
        for index in [1, 3, 5] { precondition(requests[index].value(forHTTPHeaderField: "Authorization") == "Bearer ticket-\(index)") }
        let body = try JSONSerialization.jsonObject(with: requests[0].httpBody!) as! [String: String]
        precondition(body == ["device_id": "mine", "refresh_token": "secret"])
        MockProtocol.status = 409
        do {
            try await service.removeRevoked("other")
            fatalError("Expected a conflict")
        } catch MacDeviceService.Failure.rejected(let status, let detail) {
            precondition(status == 409 && detail == "device is not revoked")
        }
        let count = MockProtocol.requests.count
        let ticketOnly = MacDeviceService(address: PairingAddress(baseURL: "wss://example.test", token: "ticket"), session: URLSession(configuration: config))
        do {
            _ = try await ticketOnly.devices()
            fatalError("Expected device pairing requirement")
        } catch MacDeviceService.Failure.devicePairingRequired { }
        precondition(MockProtocol.requests.count == count)
        print("device protocol tests passed")
    }
}
