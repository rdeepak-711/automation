# Design Spec: Improved Tickets Article Generation (2026-03-26)

## 1. Objective
Improve the quality, factual integrity, and brand neutrality of the generated L2 ticket articles for the `auto-create-site` project. The goal is to create a cleaner, more authoritative user experience that focuses on core ticket data while removing redundant or branded elements.

## 2. Key Requirements

### 2.1. Content & Data Integrity
*   **AEO (Answer Engine Optimization):** The `.att-aeo-block` must contain only the direct answer text. The question line (`Q: ...`) must be removed to prioritize a direct, "voice-ready" answer.
*   **Price Table Filtering:** Only definitive, fixed-price data points are permitted. 
    *   **Banned:** Any row containing "Reduced," "Verify on site," "Confirm in advance," or "See official site."
    *   **Focus:** Adult prices and fixed-cost children/senior tiers (only if a specific Euro amount is provided in the Blueprint).
*   **Brand Neutrality:** All mentions of third-party providers (e.g., GetYourGuide, Tiqets, Viator) must be removed from the article body, ticket labels, and descriptions.
*   **Focus:** Remove all "unrelated" or "generic" travel content. Every paragraph must serve the specific ticket or tour topic.

### 2.2. Component Changes
*   **Removals:**
    *   **Quick Facts Box:** Remove the `.att-quick-facts` component entirely.
    *   **"Where to Buy" Section:** Remove any dedicated section or body text explaining where to purchase.
    *   **"Last Verified" Footer:** Remove the verification timestamp and the "check official site" disclaimer from the bottom of the article.
*   **Additions:**
    *   **Primary CTA Button:** A high-visibility button with the text **"Buy this ticket"** must be inserted immediately above the **Insider Tip** box.
    *   **Renaming:** The "Top Tickets" banner label must be renamed to **"Ticket Options"** or **"Featured Access."**

### 2.3. UI & Formatting
*   **Collapsible FAQ:** Implement an accordion-style FAQ using native HTML `<details>` and `<summary>` tags for maximum accessibility and zero-JS dependency.
*   **Related Articles:** Transform the "pill-styled" links at the bottom into plain text links. Remove borders, backgrounds, and padding from the list items.

## 3. Technical Implementation

### 3.1. File Changes
*   **`auto-create-site/scripts/content/generate-l2-articles.sh`:** 
    *   Update the AI prompt to reflect all content constraints (AEO block format, banned words, data filtering).
    *   Add instructions for the placement of the new "Buy this ticket" button.
*   **`auto-create-site/docs/Four Pages/attraction-individual-article-template.html`:**
    *   Update CSS for `.att-related__list` to remove pill styling.
    *   Define styles for the new `.att-buy-btn` class.
    *   Replace the static FAQ structure with the `<details>`/`<summary>` pattern.
    *   Remove the `.att-quick-facts` and `.att-last-verified` structures.

### 3.2. Script Post-Processing
Ensure that the post-processing logic in `generate-l2-articles.sh` correctly handles the new HTML structure without breaking the viewport or charset tags.

## 4. Success Criteria
*   The generated article contains **zero** mentions of "GetYourGuide", "Tiqets", or "Viator."
*   The AEO block starts immediately with the answer text.
*   The FAQ items expand and collapse correctly without JavaScript.
*   The related links appear as standard text links.
*   The "Buy this ticket" button appears exactly once above the Insider Tip.
*   The price table contains only definitive pricing.
