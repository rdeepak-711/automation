# CSS Spacing Comparison — auschwitz-guide.com vs operagarnier-guide.com

**Date:** 2026-04-13  
**Scope:** All spacing-related CSS (padding, margin, max-width, width, gap) across homepage, L1 pages, and L2 posts.

---

## Verdict

**The CSS is identical across both sites.** Every spacing value, breakpoint, and container rule matches byte-for-byte. There are no differences to fix.

---

## CSS Extracted — Shared Across Both Sites

### Container / Layout

| Selector | Rule |
|---|---|
| `.att-container` | `max-width: 100%; margin: 0 auto; padding-left: 48px; padding-right: 48px` |
| `.att-section` | `padding: 60px 0` |
| `@media (min-width: 1280px)` | `.att-container { max-width: 74% !important }` |
| `@media (min-width: 1024px) and (max-width: 1279px)` | `.att-container { max-width: 82% !important }` |
| `@media (min-width: 768px) and (max-width: 1023px)` | `.att-container { max-width: 88% !important }` |
| `@media (max-width: 767px)` | `.att-container { max-width: 94% !important; padding-left: 12px !important; padding-right: 12px !important }` |
| `@media (max-width: 768px)` | `.att-container { padding-left: 10px; padding-right: 10px }` |

> **Note:** There are two overlapping mobile rules — `max-width: 768px` sets padding to `10px`, while `max-width: 767px` sets it to `12px !important`. The `!important` on the 767px rule wins. This is a minor inconsistency present on **both** sites.

---

### L2 Article Posts (`.att-article-page`)

| Selector | Rule |
|---|---|
| `.att-article-page .att-container` | `width: 74%; margin: 0 auto; padding-left: 0; padding-right: 0` |
| `@media (min-width: 769px) and (max-width: 1199px)` | `.att-article-page .att-container { width: 85% }` |
| `@media (max-width: 768px)` | `.att-article-page .att-container { width: 94%; padding-left: 0; padding-right: 0 }` |
| `.att-article-header` | `padding: 40px 0 0 0` |
| `.att-article-body` | `padding: 40px 0 60px 0` |

L2 posts use `width: 74%` (not `max-width`) and zero left/right padding — the width constraint provides the margins. This is narrower than the homepage/L1 containers which use `max-width` breakpoints.

---

### Homepage (`.att-homepage`)

| Selector | Rule |
|---|---|
| `.att-hero__inner` | `gap: 40px` |
| `.att-hero__content` | `padding: 56px 0` |
| `.att-hero__badge` | `padding: 5px 14px; margin-bottom: 18px` |
| `.att-homepage .att-hero h1` | `margin: 0 0 16px 0` |
| `.att-homepage .att-hero__desc` | `margin: 0 0 28px 0; max-width: 540px` |
| `.att-hero__actions` | `gap: 12px; margin-top: 28px` |
| `.att-tickets-grid` | `gap: 20px` |
| `.att-ticket__body` | `padding: 20px 22px 0` |
| `.att-ticket__footer` | `padding: 0 22px 20px` |
| `.att-highlights-grid` | `gap: 20px` |
| `.att-homepage .att-highlight__body` | `padding: 22px 24px` |
| `.att-homepage .att-cta-banner` | `padding: 52px 24px` |
| `.att-homepage .att-faq` | `max-width: 920px; margin: 0 auto` |

---

### L1 Pages (`.att-plan-page`, `.att-tickets-page`, `.att-see-page`)

| Selector | Rule |
|---|---|
| `.att-plan-page .att-container` | `max-width: 100%; margin: 0 auto; padding-left: 48px; padding-right: 48px` |
| `.att-plan-page .att-section` | `padding: 60px 0` |
| `.att-plan-page .att-hero__content` | `padding: 48px 0` |
| `.att-plan-page .att-hero__desc` | `margin: 0 0 28px 0; max-width: 540px` |
| `.att-articles-grid` | `gap: 20px` |
| `.att-article-card__body` | `padding: 22px 24px` |
| `.att-practical-grid` | `gap: 24px` |
| `.att-practical-card` | `padding: 32px 30px` |
| `.att-tips-grid` | `gap: 16px` |
| `.att-plan-page .att-tip` | `padding: 20px 22px; gap: 14px` |
| `.att-plan-page .att-faq` | `max-width: 920px; margin: 0 auto` |
| `.att-crosslink__body` | `padding: 24px 28px` |
| `@media (max-width: 768px)` | `.att-plan-page .att-container { padding-left: 10px; padding-right: 10px }` |

---

## Inline CSS Differences

**None.** Both sites share identical inline CSS templates.

---

## GeneratePress Theme Settings — `generate_settings`

Almost identical. Only minor differences:

| Setting | Auschwitz | Opera Garnier |
|---|---|---|
| `logo_width` | `240` | `320` |
| `footer_layout_setting` | `contained-footer` | _(not set)_ |
| `footer_inner_width` | `contained` | _(not set)_ |
| `footer_widget_setting` | `0` | _(not set)_ |

Everything else — `container_width` (1365), fonts (Karla), font sizes, line heights, heading margins — is **identical**.

---

## GeneratePress Spacing Settings — `generate_spacing_settings`

**This is where the visual difference comes from.**

| Setting | Auschwitz | Opera Garnier | What it controls |
|---|---|---|---|
| `content_top` | `10` | `0` | Top padding inside content area |
| `content_right` | `5` | `5` | ✓ same |
| `content_bottom` | `40` | `40` | ✓ same |
| `content_left` | `5` | `5` | ✓ same |
| `header_top` | `15` | `0` | Top padding inside header |
| `header_right` | `20` | `20` | ✓ same |
| `header_bottom` | `10` | `10` | ✓ same |
| `header_left` | `10` | `10` | ✓ same |
| `mobile_content_*` | all `5/30` | all `5/30` | ✓ same |

**Key differences:**
- **`content_top`**: Auschwitz `10px` vs Opera Garnier `0` — extra gap at top of every page's content area
- **`header_top`**: Auschwitz `15px` vs Opera Garnier `0` — extra breathing room above the header

Small values (10–15px) but visible, particularly where the hero banner sits at the very top.

---

## To Make Auschwitz Match Opera Garnier

```bash
SSH_AUTH_SOCK="" ssh -i ~/.ssh/id_rsa_bluehost_old -o StrictHostKeyChecking=no -o IdentitiesOnly=yes kzrmeomy@50.6.109.30 \
  "wp option update generate_spacing_settings \
    --format=json '{\"separator\":\"20\",\"content_element_separator\":\"2.4\",\"content_top\":\"0\",\"content_right\":\"5\",\"content_bottom\":\"40\",\"content_left\":\"5\",\"header_top\":\"0\",\"header_right\":\"20\",\"header_bottom\":\"10\",\"header_left\":\"10\",\"mobile_content_top\":\"30\",\"mobile_content_right\":\"5\",\"mobile_content_bottom\":\"30\",\"mobile_content_left\":\"5\"}' \
    --path=/home1/kzrmeomy/public_html/website_ce6ca565"
```
