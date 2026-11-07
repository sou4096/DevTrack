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

    func testDeleteAccountWithPassword() {
        let app = XCUIApplication()
        app.launchEnvironment["DEVTRACK_AUTH_EMULATOR"] = "1"
        app.launchEnvironment["DEVTRACK_ACCOUNT_DELETION_TEST"] = "1"
        app.launch()
        let email = app.textFields["メールアドレス"]
        XCTAssertTrue(email.waitForExistence(timeout: 20))
        email.tap()
        email.typeText("delete-ios-\(UUID().uuidString.lowercased())@example.test")
        let password = app.secureTextFields["パスワード"]
        password.tap()
        password.typeText("password123")
        app.buttons["アカウント作成"].tap()
        let deletePassword = app.secureTextFields["削除確認用パスワード"]
        XCTAssertTrue(deletePassword.waitForExistence(timeout: 20))
        deletePassword.tap()
        deletePassword.typeText("password123")
        app.buttons["パスワードで再認証して削除"].tap()
        app.buttons["削除する"].tap()
        XCTAssertTrue(app.staticTexts["削除を受け付けました。クラウド上のデータ削除はバックグラウンドで進行します。"].waitForExistence(timeout: 20))
    }
}
