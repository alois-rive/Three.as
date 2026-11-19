// The test fixtures (tests/fixtures/), read by name with `this.blob(stem)`.
//
// The suites that read a fixture skip their checks when it is missing,
// because a project that builds the engine through a library override (the
// gallery: `override: ../threeas` in its rive.yaml) compiles and runs these
// suites too, and only this project holds the fixtures. Here, where
// fixtures.txt is, every fixture it lists must be found.
import { Tests } from "rive/test";

export class FixtureTests extends Tests {
    override run(): void {
        group("Test fixtures", () => {
            test("every fixture in tests/fixtures/fixtures.txt is a blob", (expect) => {
                const list = this.blob("fixtures");
                if (list == null) return;   // not packages/threeas (a library override)
                const names = String.UTF8.decode(list!).split("\n");
                let count = 0;
                for (let i = 0; i < names.length; i++) {
                    const name = names[i].trim();
                    if (name.length == 0) continue;
                    // A failure names the fixture: "<name> is missing".
                    expect.that(this.blob(name) != null ? name : name + " is missing").is(name);
                    count++;
                }
                expect.that(count).is(50);
            });
        });
    }
}
