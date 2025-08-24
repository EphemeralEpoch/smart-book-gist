############################################################
# Log into GCP                                             #
############################################################
gcloud auth login
gcloud config set project sandbox-ahmed
gcloud auth application-default login

gcloud auth login --brief
gcloud auth list

############################################################
# Python set up                                            #
############################################################

# update package lists
sudo apt update
# install python3, pip, and venv support
sudo apt install -y python3 python3-venv python3-pip build-essential
# optional: make `python` point to python3 (convenience)
sudo apt install -y python-is-python3
# install pipx for safe global CLI tools (recommended)
python -m pip install --user pipx
python -m pipx ensurepath

############################################################
# create a projects root (if you don't already have one)   #
# create project directory                                 #
############################################################
mkdir -p ~/projects
mkdir -p ~/projects/myapp
cd ~/projects/myapp

############################################################
# create & activate virtual env                            #
############################################################
# python virtualenv
python3 -m venv .venv
# POSIX shells (bash, zsh) — the common case in WSL
source .venv/bin/activate
# or equivalently
. .venv/bin/activate

###########################################################
# execute in virtual env                                  #
###########################################################
# upgrade pip (inside system python)
python -m pip install --upgrade pip setuptools wheel

# after activation, upgrade pip inside venv
pip install --upgrade pip
pip install -r requirements.txt

set -a
. .env
set +a
source .env

############################################################
# opens this folder in VS Code (WSL mode)                  #
############################################################
code .

###########################################################
# Deploying & Testing                                     #
###########################################################
# local
python src/main.py --prompt "Summarize knut hamsun's novel hunger in 3 bullets"

# cloud
./scripts/deploy.sh


# unauthenticated 
gcloud run services describe smart-book-gist --region=us-central1 --project=sandbox-ahmed --format="value(status.url)"
curl -sS $(gcloud run services describe smart-book-gist --region=us-central1 --project=sandbox-ahmed --format="value(status.url)")/ | sed -n '1,20p'
curl -sS -X POST https://smart-book-gist-1072830302799.us-central1.run.app/generate \
  -H "Content-Type: application/json" \
  -d '{"prompt":"Summarize *Hunger* by Knut Hamsun in 3 bullets."}' | jq

# authenticated

./scripts/invoke.sh \
  https://smart-book-gist-1072830302799.us-central1.run.app \
  smart-book-gist-sa@sandbox-ahmed.iam.gserviceaccount.com \
  "Summarize Knut Hamsun's novel Hunger in 3 bullets" \
  0.2 \
  800 \
  "openai/gpt-oss-20b"

  ./scripts/invoke.sh \
  https://smart-book-gist-1072830302799.us-central1.run.app \
  smart-book-gist-sa@sandbox-ahmed.iam.gserviceaccount.com \
  "Summarize Franz Kafka's novel Metamorphosis in 3 bullets" \
  0.2 \
  800 \
  "openai/gpt-oss-20b"

###############debuging#####################################
gcloud run services add-iam-policy-binding smart-book-gist \
  --region=us-central1 \
  --member="serviceAccount:smart-book-gist-sa@sandbox-ahmed.iam.gserviceaccount.com" \
  --role="roles/run.invoker" \
  --project=sandbox-ahmed

gcloud secrets versions list groq-api-key --project=sandbox-ahmed

###########################################################

gcloud iam service-accounts delete smart-book-gist-sa@sandbox-ahmed.iam.gserviceaccount.com --project=sandbox-ahmed
gcloud secrets delete groq-api-key --project=sandbox-ahmed --quiet
gcloud config unset auth/impersonate_service_account
