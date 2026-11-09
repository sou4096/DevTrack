import XCTest

func dismissSystemPasswordPromptIfPresent() {
    let app = XCUIApplication()
    let decline = app.buttons.matching(NSPredicate(format: "label IN %@", ["今はしない", "Not Now"])).firstMatch
    if decline.waitForExistence(timeout: 4) {
        decline.tap()
        XCTAssertTrue(decline.waitForNonExistence(timeout: 5))
    }
}

final class AuthenticationUITests: XCTestCase {
    private func prepareLogin(_ app: XCUIApplication) {
        let account = app.buttons["アカウント"]
        if account.waitForExistence(timeout: 3) {
            account.tap()
            if app.buttons["ログアウト"].waitForExistence(timeout: 5) { app.buttons["ログアウト"].tap() }
        }
    }
    func testRegistrationAndLoginImmediatelyAllowNavigation() {
        let app = XCUIApplication()
        app.launchEnvironment["DEVTRACK_AUTH_EMULATOR"] = "1"
        app.launch()
        prepareLogin(app)
        let email = app.textFields["メールアドレス"]
        XCTAssertTrue(email.waitForExistence(timeout: 20))
        email.tap()
        let address = "ios-\(UUID().uuidString.lowercased())@example.test"
        email.typeText(address)
        let password = app.secureTextFields["パスワード"]
        password.tap()
        password.typeText("password123")
        app.buttons["アカウント作成"].tap()
        XCTAssertTrue(app.buttons["アカウント"].waitForExistence(timeout: 20))
        dismissSystemPasswordPromptIfPresent()
        let account = app.buttons["アカウント"]
        XCTAssertTrue(account.waitForExistence(timeout: 20))
        account.tap()
        let signOut = app.buttons["ログアウト"]
        XCTAssertTrue(signOut.waitForExistence(timeout: 20))
        signOut.tap()
        XCTAssertTrue(app.buttons["ログイン"].waitForExistence(timeout: 10))
        let loginEmail = app.textFields["メールアドレス"]
        loginEmail.tap(); loginEmail.typeText(address)
        let loginPassword = app.secureTextFields["パスワード"]
        loginPassword.tap(); loginPassword.typeText("password123")
        app.buttons["ログイン"].tap()
        XCTAssertTrue(app.buttons["アカウント"].waitForExistence(timeout: 20))
        dismissSystemPasswordPromptIfPresent()
        app.buttons["アカウント"].tap()
        XCTAssertTrue(app.buttons["ログアウト"].waitForExistence(timeout: 10))
    }

    func testAccountCanRequestDeletionWithPassword() {
        let app = XCUIApplication()
        app.launchEnvironment["DEVTRACK_AUTH_EMULATOR"] = "1"
        app.launchEnvironment["DEVTRACK_ACCOUNT_DELETION_TEST"] = "1"
        app.launch()
        prepareLogin(app)
        let email = app.textFields["メールアドレス"]
        XCTAssertTrue(email.waitForExistence(timeout: 20))
        email.tap()
        email.typeText("delete-ios-\(UUID().uuidString.lowercased())@example.test")
        let password = app.secureTextFields["パスワード"]
        password.tap()
        password.typeText("password123")
        app.buttons["アカウント作成"].tap()
        XCTAssertTrue(app.buttons["アカウント"].waitForExistence(timeout: 20))
        dismissSystemPasswordPromptIfPresent()
        let account = app.buttons["アカウント"]
        XCTAssertTrue(account.waitForExistence(timeout: 20))
        account.tap()
        let deletePassword = app.secureTextFields["削除確認用パスワード"]
        XCTAssertTrue(deletePassword.waitForExistence(timeout: 20))
        deletePassword.tap()
        deletePassword.typeText("password123")
        app.buttons["パスワードで再認証して削除"].tap()
        app.buttons["削除する"].tap()
        XCTAssertTrue(app.staticTexts["削除を受け付けました。クラウド上のデータ削除はバックグラウンドで進行します。"].waitForExistence(timeout: 20))
    }
}
