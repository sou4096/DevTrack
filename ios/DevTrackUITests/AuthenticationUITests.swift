import XCTest

final class AuthenticationUITests: XCTestCase {
    func testEmailRegistrationAndSignOut() {
        let app = XCUIApplication()
        app.launchEnvironment["DEVTRACK_AUTH_EMULATOR"] = "1"
        app.launch()
        let email = app.textFields["メールアドレス"]
        XCTAssertTrue(email.waitForExistence(timeout: 20))
        email.tap()
        email.typeText("ios-\(UUID().uuidString.lowercased())@example.test")
        let password = app.secureTextFields["パスワード"]
        password.tap()
        password.typeText("password123")
        app.buttons["アカウント作成"].tap()
        let signOut = app.buttons["ログアウト"]
        XCTAssertTrue(signOut.waitForExistence(timeout: 20))
        signOut.tap()
        XCTAssertTrue(app.buttons["ログイン"].waitForExistence(timeout: 10))
    }
}
