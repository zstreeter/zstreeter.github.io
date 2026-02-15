# zstreeter.github.io

Personal blog built with [Quarto](https://quarto.org/).

## Prerequisites

- [Quarto](https://quarto.org/docs/get-started/) (>= 1.4)
- Python 3.12+

## Setup

```bash
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

## Local Development

```bash
quarto preview
```

Opens a browser with live reload on file changes.

## Build

```bash
quarto render
```

Output goes to `_site/`.

## Deploy

Pushes to `main` trigger the GitHub Actions workflow which runs `quarto publish gh-pages`.
