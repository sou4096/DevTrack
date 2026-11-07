import XCTest

final class LocalTimerUITests: XCTestCase {
    func testCreateProjectAndRecordTimer() {
        let app = XCUIApplication()
        app.launchEnvironment["DEVTRACK_AUTH_EMULATOR"] = "1"
        app.launch()
        if app.buttons["アカウント"].waitForExistence(timeout: 3) {
            app.buttons["アカウント"].tap()
            if app.buttons["ログアウト"].waitForExistence(timeout: 5) { app.buttons["ログアウト"].tap() }
        }
        let email = app.textFields["メールアドレス"]
        XCTAssertTrue(email.waitForExistence(timeout: 20))
        email.tap(); email.typeText("timer-\(UUID().uuidString.lowercased())@example.test")
        let password = app.secureTextFields["パスワード"]
        password.tap(); password.typeText("password123")
        app.buttons["アカウント作成"].tap()
        XCTAssertTrue(app.tabBars.buttons["ホーム"].waitForExistence(timeout: 20))
        app.terminate(); app.launch()
        let projects = app.tabBars.buttons["プロジェクト"]
        XCTAssertTrue(projects.waitForExistence(timeout: 20))
        projects.tap()
        let field = app.textFields["プロジェクト名"]
        field.tap(); field.typeText("Sample Project")
        app.buttons["プロジェクトを追加"].tap()
        XCTAssertTrue(app.staticTexts["Sample Project"].waitForExistence(timeout: 5))
        app.tabBars.buttons["ホーム"].tap()
        app.buttons["projectPicker"].tap()
        app.buttons["Sample Project"].tap()
        app.buttons["計測開始"].tap()
        XCTAssertTrue(app.buttons["一時停止"].waitForExistence(timeout: 5))
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["一時停止"].waitForExistence(timeout: 20))
        app.buttons["一時停止"].tap()
        XCTAssertTrue(app.buttons["再開"].waitForExistence(timeout: 5))
        app.buttons["再開"].tap()
        app.buttons["終了"].tap()
        app.tabBars.buttons["履歴"].tap()
        XCTAssertTrue(app.staticTexts["Sample Project"].waitForExistence(timeout: 5))
    }
}
