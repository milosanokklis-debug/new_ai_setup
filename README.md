Setup Instructuions:

chmod +x agent-kit.sh

# 1. Build the kit (copies upstream skills, writes manifests and agents, validates, git-inits)
./agent-kit.sh init ~/agent-kit

# 2. Push it to GitHub (private is fine)
cd ~/agent-kit && git remote add origin git@github.com:YOU/agent-kit.git && git push -u origin HEAD && cd -

# 3. Register the upstream marketplaces plus yours (catalogs only, nothing loads yet)
./agent-kit.sh register ~/agent-kit

# 4. Wire each project; kit-core is always included
KIT_REPO=YOU/agent-kit ./agent-kit.sh project ~/code/my-web-app design code
KIT_REPO=YOU/agent-kit ./agent-kit.sh project ~/code/my-api code
KIT_REPO=YOU/agent-kit ./agent-kit.sh project ~/code/big-repo code --graph   # adds graphify

# Later
./agent-kit.sh sync ~/agent-kit     # re-pull upstream skills, then review the diff and push
./agent-kit.sh doctor               # installed plugins and their token cost
./agent-kit.sh free                 # throwaway freellmapi session in its own git worktree
