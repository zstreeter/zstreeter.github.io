# Blogging Guide

## Creating a New Post

1. Create a directory under `posts/` named with the date and slug:

   ```
   posts/2025-01-15-my-post/index.qmd
   ```

2. Add front matter:

   ```yaml
   ---
   title: "My Post Title"
   author: "Zachary Streeter"
   date: 2025-01-15
   categories: [AI, Deep Learning]
   description: "A brief summary."
   image: preview.png
   ---
   ```

3. Write content using standard Quarto markdown.

## Features

### Math

LaTeX math works natively:

```
Inline: $E = mc^2$
Display: $$\int_0^\infty e^{-x} dx = 1$$
```

### Code Execution

Python code cells execute natively --- no intermediary steps:

````
```{python}
import numpy as np
print(np.arange(10))
```
````

### Callouts

```
:::{.callout-tip}
This is a tip callout.
:::

:::{.callout-warning}
This is a warning callout.
:::
```

### Code Folding

Enabled globally in `_quarto.yml`. Readers can expand/collapse code blocks.

### Interactive Plots

Plotly and other interactive libraries work out of the box.

## Local Preview

```bash
quarto preview
```

Changes to `.qmd` files trigger automatic re-render with live reload.

## Freeze

`execute: freeze: auto` in `_quarto.yml` caches computation results in `_freeze/`.
The `_freeze/` directory is tracked in git so CI doesn't need to re-execute code.

## Project Structure

```
zstreeter.github.io/
├── _quarto.yml              # Site configuration
├── index.qmd                # Home page with blog listing
├── about.qmd                # About page
├── posts/
│   └── YYYY-MM-DD-slug/
│       └── index.qmd        # Blog post
├── images/                  # Site-wide images
├── styles.css               # Custom CSS
├── requirements.txt         # Python dependencies
└── .github/
    └── workflows/
        └── publish.yml      # CI/CD pipeline
```
