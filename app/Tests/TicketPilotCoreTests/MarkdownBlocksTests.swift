import Testing
@testable import TicketPilotCore

struct MarkdownBlocksTests {
    @Test func readsTheBlocksOfAReport() {
        let text = """
        # Rapport — ABC-1

        > Ajouté après
        > ce rapport.

        Les 3 commits **buildent**
        et passent.

        ## Commits

        | Commit | Tests |
        |---|---|
        | `abc fix` | ✅ |

        - **Découpage :** le renommage
          passe en premier.
        1. Distance affichée

        ```
        git review
        ```
        ---
        """
        #expect(MarkdownBlocks.parse(text) == [
            .heading(level: 1, text: "Rapport — ABC-1"),
            .quote("Ajouté après ce rapport."),
            .paragraph("Les 3 commits **buildent** et passent."),
            .heading(level: 2, text: "Commits"),
            .table(header: ["Commit", "Tests"], rows: [["`abc fix`", "✅"]]),
            .listItem(marker: "•", text: "**Découpage :** le renommage passe en premier."),
            .listItem(marker: "1.", text: "Distance affichée"),
            .code("git review"),
            .rule,
        ])
    }

    @Test func hashWithoutSpaceIsText() {
        #expect(MarkdownBlocks.parse("#3518 est mergé") == [.paragraph("#3518 est mergé")])
    }
}
