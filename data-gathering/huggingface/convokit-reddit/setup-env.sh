#!/bin/bash
# setup-env.sh - Sets up a clean virtual environment for Convokit + your conversation tools

set -e  # Exit on any error

echo "🚀 Setting up virtual environment for conversation datasets..."

# 1. Create virtual environment
VENV_NAME="convokit-env"

if [ ! -d "$VENV_NAME" ]; then
    echo "Creating virtual environment '$VENV_NAME'..."
    python3 -m venv "$VENV_NAME"
else
    echo "Virtual environment '$VENV_NAME' already exists."
fi

# 2. Activate it
echo "Activating virtual environment..."
source "$VENV_NAME/bin/activate"

# 3. Upgrade pip
echo "Upgrading pip..."
pip install --upgrade pip

# 4. Install required packages
echo "Installing Convokit and dependencies..."
pip install convokit

# Optional but recommended for better NLP
pip install spacy
python -m spacy download en_core_web_sm

# Additional useful libs for your app
pip install pandas tqdm  # For data handling and progress

echo ""
echo "✅ Setup complete!"
echo ""
echo "To activate the environment in the future, run:"
echo "    source $VENV_NAME/bin/activate"
echo ""
echo "To run your script:"
echo "    source $VENV_NAME/bin/activate"
echo "    python get_conversation_samples.py"
echo ""
echo "Done! You can now run the sample script."