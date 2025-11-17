Here's our project structure:

* `main.tf`: Declares our provider (AWS) and configures the S3 remote state.
* `variables.tf`: Defines our inputs (like VPC CIDR, instance types).
* `network.tf`: Builds the "house" (VPC, subnets, route tables, gateways).
* `security.tf`: Builds the "locks and keys" (Security Groups, IAM Roles).
* `storage.tf`: Creates our S3 bucket for SmartStore and our secrets.
* `compute.tf`: Launches the "appliances" (EC2 instances, Launch Templates).
* `load_balancing.tf`: Manages the "front doors" (Load Balancers).
* `dns.tf`: Sets up the "street signs" (Route 53 DNS records).

Let's walk through each step, explaining the "why" for each AWS service.

---

### 🏛️ Step 1: The Foundation (`network.tf`)

Before you can launch a single server, you need a private, isolated network for it to live in. This is your **VPC (Virtual Private Cloud)**.

* **Why AWS VPC?** A VPC is your own logically isolated section of the AWS cloud. It's the foundational boundary for your entire deployment.
* **What We'll Build:**
    * **`aws_vpc`:** This is the main container. We'll give it a private IP range (e.g., `10.0.0.0/16`).
    * **Subnets (`aws_subnet`):** We'll divide our VPC into smaller networks. Best practice is to have:
        * **Public Subnets:** For resources that *must* face the internet, like our Load Balancers and a NAT Gateway.
        * **Private Subnets:** For our Splunk instances (SH, IDX, DS, UFs). We want them to be secure and *not* directly accessible from the internet.
    * **Internet Gateway (`aws_internet_gateway`):** This attaches to our VPC to allow resources in the *public subnets* to communicate with the internet.
    * **NAT Gateway (`aws_nat_gateway`):** This sits in a *public subnet* (and needs an `aws_eip` or Elastic IP). It allows instances in our *private subnets* to make outbound connections (e.g., to download Splunk updates or send data to AWS APIs) while preventing the internet from initiating connections *back* to them. This is a critical security component.
    * **Route Tables (`aws_route_table`):** These act as the "traffic cop." We'll have:
        * A **Public Route Table:** Says "all internet-bound traffic (0.0.0.0/0) goes to the Internet Gateway." Associated with public subnets.
        * A **Private Route Table:** Says "all internet-bound traffic (0.0.0.0/0) goes to the NAT Gateway." Associated with private subnets.

---

### 🔐 Step 2: Security & Identity (`security.tf`)

Now we have our network, but we need rules for who can talk to what.

* **Why AWS Security Groups (SGs)?** SGs are stateful firewalls at the *instance level*. This is our primary tool for controlling traffic *between* Splunk components. We'll create SGs based on *role*.
    * **`sg_splunk_web`:** For the Search Head. Allows inbound port `8000` (Splunk Web) from our Load Balancer and our office IP.
    * **`sg_splunk_indexer`:** For the Indexer. Allows inbound port `9997` (forwarding) from the `sg_splunk_uf` group, and port `8089` (management) from the `sg_splunk_sh` and `sg_splunk_ds` groups.
    * **`sg_splunk_uf`:** For the Universal Forwarders. Allows outbound traffic on port `9997` to the `sg_splunk_indexer` group.
    * **`sg_splunk_ds`:** For the Deployment Server. Allows port `8089` from `sg_splunk_uf`.
* **Why AWS IAM (Identity and Access Management)?** We *never* want to put secret keys (like AWS access keys) on our instances. Instead, we grant permissions to the instances themselves using **IAM Roles**.
    * **`iam_role_splunk_indexer`:** This is the most important one. This role needs policies that allow it to read and write to our SmartStore S3 bucket.
    * **`iam_role_splunk_common`:** A basic role for all other instances that allows them to fetch secrets from **AWS Secrets Manager**.
    * **`aws_iam_instance_profile`:** This is the resource that "wraps" the IAM role so it can be attached to an EC2 instance.

---

### 📦 Step 3: Storage & Secrets (`storage.tf`)

We need a place to store data long-term and a place to keep our passwords.

* **Why AWS S3 (Simple Storage Service)?** This is the key to **Splunk SmartStore**. S3 provides virtually unlimited, highly durable, and cost-effective object storage. By using SmartStore, our indexer's "warm" and "cold" data lives in S3. This decouples storage from compute, meaning we can scale our indexers (compute) without having to re-provision massive (and expensive) EBS volumes.
    * **`aws_s3_bucket`:** We'll create one private S3 bucket (e.g., `my-splunk-lab-smartstore-12345`) to be the remote store.
* **Why AWS Secrets Manager?** You can't have a secure, automated (IaC) setup if you're hardcoding your Splunk admin password or `pass4SymmKey` in a text file.
    * **`aws_secretsmanager_secret`:** We'll use this to store our Splunk admin password. Our instances will use their IAM role to fetch this secret securely during their boot-up script.

---

### 💻 Step 4: Compute & Configuration (`compute.tf`)

This is where we bring our servers to life. The key to automation here is **Launch Templates** and **`user_data`**.

* **Why AWS AMI (Amazon Machine Image)?** This is our "golden image" or base OS. We'll use the `data "aws_ami"` source in Terraform to find the latest Amazon Linux 2 AMI.
* **Why AWS Launch Templates (`aws_launch_template`)?** A Launch Template is a *blueprint* for our EC2 instances. It defines the AMI, instance type, Security Groups, IAM Instance Profile, and most importantly, the **`user_data`** script. This is *much* cleaner than defining all this in the `aws_instance` resource itself. We'll create a separate Launch Template for each Splunk role (SH, IDX, DS, UF).
* **Why `user_data` (Cloud-Init)?** This is a script that runs *once* when the instance first boots. This is how we automate the Splunk installation and configuration. A typical `user_data` script for our Indexer would:
    1.  Update the OS (`yum update -y`).
    2.  Use the AWS CLI to fetch the admin password from Secrets Manager.
    3.  Download the Splunk Enterprise `.tgz` package.
    4.  Install Splunk, accepting the license and setting it to start on boot (passing in the fetched admin password).
    5.  Edit `server.conf` to configure this instance as an indexer and set up the S3 SmartStore settings (pointing to the S3 bucket we created).
    6.  Start the Splunk service.
* **Why AWS EC2 (`aws_instance`)?** These are our virtual servers. We will create:
    * `aws_instance.search_head` (using the `lt_splunk_sh` Launch Template)
    * `aws_instance.indexer` (using the `lt_splunk_idx` Launch Template)
    * `aws_instance.deployment_server` (using the `lt_splunk_ds` Launch Template)
    * `aws_instance.forwarder[2]` (using a `count = 2` meta-argument and the `lt_splunk_uf` Launch Template)

---

### 🌐 Step 5: Access & DNS (`load_balancing.tf` & `dns.tf`)

Your user requested a "load balancer with 1:1 mapping." This is an interesting request. An LB is typically used to balance traffic across *multiple* instances (like in a cluster). For a 1:1 lab, it's a bit of overkill, but it's a key AWS service to learn, so let's implement it in a way that *prepares* for clustering.

* **Why AWS Application Load Balancer (ALB)?** An ALB (`aws_lb`) is a smart, L7 (HTTP/S) load balancer. It's perfect for web UIs. We'll use one for our **Search Head** and **Deployment Server** UIs.
    * **`aws_lb_target_group`:** We'll create one target group for the SH (pointing to its instance on port 8000) and another for the DS (also on port 8000).
    * **`aws_lb_listener`:** We'll create one HTTPS listener on the ALB. Then we'll use **path-based routing**:
        * Requests for `https://splunk.my-lab.com/sh/*` get routed to the Search Head.
        * Requests for `https://splunk.my-lab.com/ds/*` get routed to the Deployment Server.
    * This is a much more efficient and realistic setup than creating a separate LB for each instance.
* **Why AWS Network Load Balancer (NLB)?** (For Bonus Points) For data ingestion (HEC on 8088 or forwarding on 9997), an NLB is superior. It's a high-performance L4 balancer. In your lab, we'd point this to our single indexer, but in production, it would point to the whole indexer cluster.
* **Why AWS Route 53?** This is AWS's highly available DNS service. This is how we create the friendly, human-readable URLs.
    * **`aws_route53_record`:** We'll create `A` (Alias) records. These are a special AWS-only record type that lets you point your domain (e.g., `splunk.my-lab.com`) directly to an AWS resource like our ALB. It's smarter than a CNAME. We'll create records like:
        * `sh.splunk.my-lab.com` -> Alias to our ALB.
        * `ds.splunk.my-lab.com` -> Alias to our ALB.
        * `idx-ingest.splunk.my-lab.com` -> Alias to our NLB (for the UFs to use).

This entire structure gives you a fully-automated, secure, and repeatable Splunk lab that is built on the same principles as the production-grade system you've seen at work.

This is the high-level blueprint. The next step is to start writing the actual Terraform HCL code for the first file, `network.tf`.

Would you like me to help you sketch out the key resources and their attributes for the `network.tf` file?