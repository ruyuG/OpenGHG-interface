#!/bin/bash
# Check if the script was run without any arguments
if [ -z "$1" ]; then
    echo "Usage: $0 {install|start|stop}"
    echo ""
    exit 1
fi


# Configuration
SERVER="bp1-login.acrc.bris.ac.uk"
USERNAME="" 
GITHUB_REPO_URL="https://github.com/ruyuG/openghg-interface.git"
STREAMLIT_APP="Home.py"
LOCAL_PORT=8503 #The local port to be used for port forwarding, allowing local access to the remote app.
REPO_NAME="openghg-interface"
INFO_FILE="\$HOME/\$REPO_NAME/.streamlit_info"  # Hidden file for port and PID


install_streamlit() {
    # username
    read -p "Enter your username for $SERVER: " USERNAME

    # SSH login test
    echo "Testing SSH login..."
    if ssh -o BatchMode=yes -o ConnectTimeout=5 $USERNAME@$SERVER exit 2>/dev/null; then
        echo "SSH login successful. Proceeding with the setup..."
    else
        echo "SSH login failed. Setting up SSH key for password-less login..."
        # check ssh key
        SSH_KEY="$HOME/.ssh/id_rsa"
        if [ ! -f "$SSH_KEY" ]; then
            echo "No SSH key found. Generating one..."
            ssh-keygen -t rsa -N "" -f $SSH_KEY
            echo "SSH key generated."
        else
            echo "SSH key already exists."
        fi

        # try to copy SSH key to server
        echo "Trying to copy SSH key to $SERVER..."
        ssh-copy-id -i $SSH_KEY.pub $USERNAME@$SERVER
    fi


    # login server and set env
    ssh -t $USERNAME@$SERVER bash << EOF
        set -e

        echo "Loading Python module..."

        module load languages/python/3.12.3 || { echo "Failed to load Python module"; exit 1; }

        # Check Virtual environment 'streamlit-env'
        if [ -d "\$HOME/streamlit-env" ]; then
            echo "Virtual environment 'streamlit-env' already exists. Activating it..."
            source \$HOME/streamlit-env/bin/activate || { echo "Failed to activate environment"; exit 1; }
        else
            echo "Creating Python virtual environment..."
            python -m venv \$HOME/streamlit-env || { echo "Failed to create environment"; exit 1; }
            source \$HOME/streamlit-env/bin/activate || { echo "Failed to activate environment"; exit 1; }
        fi

        echo "Upgrading pip..."
        pip install --upgrade pip || { echo "Failed to upgrade pip"; exit 1; }

        # Clone or update GitHub repository
        REPO_NAME="openghg-interface"

        if [ ! -d "\$REPO_NAME" ]; then
            echo "Cloning the GitHub repository..."
            git clone $GITHUB_REPO_URL \$REPO_NAME || { echo "Failed to clone repository"; exit 1; }
        else
            echo "Repository already exists. Updating..."
            cd \$REPO_NAME
            git pull || { echo "Failed to update repository"; exit 1; }
            cd ..
        fi

        echo "Installing dependencies from requirements.txt..."
        pip install -r \$REPO_NAME/requirements.txt || { echo "Failed to install dependencies"; exit 1; }

        echo "Configuring openghg..."
        expect -c '
            set timeout 30
            spawn python
            expect ">>>"
            send "from openghg.util import create_config\r"
            send "create_config(silent=False)\r"
            expect "Would you like to update the path? (y/n):"
            send "n\r"
            set store_names [list "obs_store1" "spital_store2"]
            set store_paths [list "/group/chemistry/acrg/object_stores/paris/obs_nir_2024_01_25_store_zarr" "/group/chemistry/acrg/object_stores/updated/shared_store_zarr"]
            set store_permissions [list "r" "r"] 
            set store_count [llength \$store_names]
            for {set i 0} {\$i < \$store_count} {incr i} {
                expect "Would you like to add another object store? (y/n):"
                send "y\r"
                expect "Enter the name of the store:"
                send "[lindex \$store_names \$i]\r"
                expect "Enter the object store path:"
                send "[lindex \$store_paths \$i]\r"
                expect "Enter object store permissions:"
                send "[lindex \$store_permissions \$i]\r"
            }
            expect "Would you like to add another object store? (y/n):"
            send "n\r"
            expect "Configuration written"
            send "exit()\r"
            expect eof
        '
        
        echo "Environment setup complete."
        
 
        echo "Starting Streamlit app..."
        # Clone or update GitHub repository
        #REPO_NAME=\"$REPO_NAME\"
        INFO_FILE="\$HOME/\$REPO_NAME/.streamlit_info"
        cd \$HOME/\$REPO_NAME
        streamlit run $STREAMLIT_APP > streamlit.log 2>&1 &

        # Capture Streamlit PID
        STREAMLIT_PID=\$!
        echo "Streamlit started with PID: \$STREAMLIT_PID."

        # Wait a few seconds for Streamlit to initialize
        sleep 5
        # Wait for Streamlit to start up
        echo "Waiting for Streamlit to start..."
        for i in {1..30}; do
            if grep "Local URL" streamlit.log; then
                echo "Streamlit started successfully."
                # Capture port and PID into .streamlit_info
                PORT=\$(grep "Local URL" streamlit.log | awk -F':' '{print \$4}')
                
                # Ensure it's a valid numeric port
                if [[ "\$PORT" =~ ^[0-9]+$ ]]; then
                    mkdir -p \$HOME/\$REPO_NAME
                    echo \$PORT > \$HOME/\$REPO_NAME/.streamlit_info
                    echo \$STREAMLIT_PID >> \$HOME/\$REPO_NAME/.streamlit_info
                else
                    echo "Failed to extract a valid port from the log."
                    exit 1
                fi
                break
            fi
            echo "Waiting... $i/30"
            sleep 5
        done

        # Check if the .streamlit_info file was created
        if [ ! -f "\$INFO_FILE" ]; then
            echo "Failed to start Streamlit or capture URL."
            cat \$HOME/\$REPO_NAME/streamlit.log  # Output the log for debugging
            exit 1
        fi

        # Output port and PID
        cat \$INFO_FILE
EOF

   # Read remote port and set up local port forwarding
    REMOTE_PORT=$(ssh $USERNAME@$SERVER "bash -c '
        REPO_NAME=\"openghg-interface\"
        INFO_FILE=\"\$HOME/\$REPO_NAME/.streamlit_info\"

        head -n 1 \$INFO_FILE
    '")
    ssh -L $LOCAL_PORT:localhost:$REMOTE_PORT -N -f $USERNAME@$SERVER
    echo -e "\033[0;32mStreamlit app started. Access at \033[0;34mhttp://localhost:$LOCAL_PORT\033[0m"
}


# Helper function to read the PID
get_streamlit_pid() {
    echo "now is pid step"
    
    # Check if the info file exists on the remote server
    if ! ssh $USERNAME@$SERVER "[ -f \$HOME/$REPO_NAME/.streamlit_info ]"; then
        echo "Info file not found: \$HOME/$REPO_NAME/.streamlit_info"
        exit 1
    fi

    # Read the PID from the file on the remote server
    STREAMLIT_PID=$(ssh $USERNAME@$SERVER "sed -n '2p' \$HOME/$REPO_NAME/.streamlit_info")

    if [ -z "$STREAMLIT_PID" ]; then
        echo "Failed to read PID from \$HOME/$REPO_NAME/.streamlit_info"
        exit 1
    fi
}
# Function to start the Streamlit app (if already installed)
start_streamlit() {
    read -p "Enter your username for $SERVER: " USERNAME
    echo "Starting Streamlit app on remote server..."
    #ssh -tt $USERNAME@$SERVER << EOF
    ssh $USERNAME@$SERVER << EOF
        source \$HOME/streamlit-env/bin/activate
        REPO_NAME="openghg-interface"
        INFO_FILE="\$HOME/\$REPO_NAME/.streamlit_info"
        
        cd \$HOME/\$REPO_NAME
        # Clear the old streamlit log file
        > streamlit.log
        streamlit run $STREAMLIT_APP > streamlit.log 2>&1 &

        # Capture Streamlit PID
        STREAMLIT_PID=\$!
        echo "Streamlit started with PID: \$STREAMLIT_PID."

        # Wait a few seconds for Streamlit to initialize
        sleep 5
        # Wait for Streamlit to start up
        echo "Waiting for Streamlit to start..."
        for i in {1..30}; do
            if grep "Local URL" streamlit.log; then
                echo "Streamlit started successfully."
                # Capture port and PID into .streamlit_info
                PORT=\$(grep "Local URL" streamlit.log | awk -F':' '{print \$4}')
                
                # Ensure it's a valid numeric port
                if [[ "\$PORT" =~ ^[0-9]+$ ]]; then
                    mkdir -p \$HOME/\$REPO_NAME
                    echo \$PORT > \$HOME/\$REPO_NAME/.streamlit_info
                    echo \$STREAMLIT_PID >> \$HOME/\$REPO_NAME/.streamlit_info
                else
                    echo "Failed to extract a valid port from the log."
                    exit 1
                fi
                break
            fi
            echo "Waiting... $i/30"
            sleep 5
        done

        # Check if the .streamlit_info file was created
        if [ ! -f "\$INFO_FILE" ]; then
            echo "Failed to start Streamlit or capture URL."
            cat \$HOME/\$REPO_NAME/streamlit.log  # Output the log for debugging
            exit 1
        fi

        # Output port and PID
        cat \$INFO_FILE
EOF

   # Read remote port and set up local port forwarding
    REMOTE_PORT=$(ssh $USERNAME@$SERVER "bash -c '
        REPO_NAME=\"openghg-interface\"
        INFO_FILE=\"\$HOME/\$REPO_NAME/.streamlit_info\"

        head -n 1 \$INFO_FILE
    '")
    ssh -L $LOCAL_PORT:localhost:$REMOTE_PORT -N -f $USERNAME@$SERVER
    echo -e "\033[0;32mStreamlit app started. Access at \033[0;34mhttp://localhost:$LOCAL_PORT\033[0m"
}



stop_streamlit() {
    read -p "Enter your username for $SERVER: " USERNAME
    get_streamlit_pid

    # Check if the PID is valid
    if [ -z "$STREAMLIT_PID" ]; then
        echo "No PID found in $INFO_FILE"
        exit 1
    fi

    # Check if the process is running before attempting to terminate it
    PROCESS_STATUS=$(ssh $USERNAME@$SERVER "ps -p $STREAMLIT_PID")
    if [ -z "$PROCESS_STATUS" ]; then
        echo "Streamlit process with PID $STREAMLIT_PID is not running. Removing info file."
    else
        echo "Attempting to terminate Streamlit process with PID $STREAMLIT_PID..."
        ssh $USERNAME@$SERVER "kill $STREAMLIT_PID"

        # Wait a few seconds to see if the process terminates
        sleep 5

        # Check if the process is still running
        PROCESS_STATUS=$(ssh $USERNAME@$SERVER "ps -p $STREAMLIT_PID")
        if [ -n "$PROCESS_STATUS" ]; then
            echo "Process did not terminate, forcing shutdown with kill -9..."
            ssh $USERNAME@$SERVER "kill -9 $STREAMLIT_PID"
        else
            echo "Streamlit process terminated gracefully."
        fi
    fi

    # Remove the Streamlit info file
    echo "Attempting to remove the Streamlit info file..."
    ssh $USERNAME@$SERVER "if [ -f \$HOME/$REPO_NAME/.streamlit_info ]; then rm \$HOME/$REPO_NAME/.streamlit_info; else echo 'Info file not found'; fi"
    
    echo "Streamlit process stopped and info file removed."

    # Stop local port forwarding
    echo "Stopping local port forwarding on port $LOCAL_PORT..."
    kill $(lsof -ti :$LOCAL_PORT) || echo "No process was listening on port $LOCAL_PORT"
    
    echo "Streamlit process and local port forwarding stopped."
}
# Main logic to determine install, start or stop
if [ "$1" == "install" ]; then
    install_streamlit
elif [ "$1" == "start" ]; then
    start_streamlit
elif [ "$1" == "stop" ]; then
    stop_streamlit
else
    echo "Usage: $0 {install|start|stop}"
    exit 1
fi